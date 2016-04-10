from multiprocessing.pool import Pool
from queue import Queue, Empty

import cython, math
from numpy import float32, int32
from blas.cy cimport sdot, saxpy
from pipe.cy import cypipe

from tools.taketime import taketime
import threading

import numpy as np
cimport numpy as np

cdef unsigned long long rand = 25214903917
cdef int ONE = 1
cdef int ZERO = 0
cdef cREAL fONE = 1.0
cdef cREAL fZERO = 0.0

# contains the configuration for the network, the solution space (to be used after training) and can build the
# processing pipeline to learn the model.
# For the learning pipeline a c-projection of this model is made to be passed through the pipeline.
class model:
    def __init__(self, alpha,
                 input, build, pipeline,
                 mintf=1, cores=1, windowsize=5, iterations=1, **kwargs):
        self.__dict__.update(kwargs)
        self.windowsize = windowsize        # windowsize used for w2v models
        self.alpha = alpha                  # initial learning rate
        self.iterations = iterations        # number of times to iterate over the corpus
        self.mintf = mintf                  # minimal collection frequency for terms to be used
        self.build = build                  # functions called with (model) to construct the model
        self.pipeline = pipeline            # python functions that process the input word generator
        self.cores = cores                  # number of cores/threads to use in multithreading mode
        self.input = input                  # reusable list of generators that generate input, used twice to build the
                                            # vocabulary and reused to learn the model
        self.progress = np.zeros((cores), dtype=int32)  # tracks progress per thread
        self.pipe = [None] * cores          # first pipelineobject per thread

    # Builds the vocabulay, then build the learning pipeline, and push the inputs through the pipeline.
    def run(self):

        # build the model
        for f in self.build:
            f(self)

        # instantiate the processing pipelines
        self.createPipes()

        # when there is only one core or one input, run in single mode,
        # otherwise run multithreaded, learning the model in parallel.
        # The current version requires the cores to be on a single machine with shared memory.
        if len(self.input) == 1 or self.cores == 1:
            for input in self.input:
                self.pipe[0].feed(input)
        else:
            threads = []
            queue = Queue(len(self.input))
            for i in self.input:
                queue.put(i)
            for i in range(self.cores):
                t = threading.Thread(target=learnThread, args=(i, self, queue))
                t.daemon = True
                threads.append(t)
                t.start()
            for t in threads:
                t.join()

    def setSolution(self, solution):
        self.solution = solution
        self.getModelC().setSolution(solution)

    def createPipes(self):
        def createPipe(threadid):
            previous = self.pipe[threadid] = self.pipeline[0](threadid, self)
            for i in range(1, len(self.pipeline)):
                next = self.pipeline[i](threadid, self)
                next.bindTo(previous)
                previous = next

        for t in range(self.cores):
            createPipe(t) # initialize the first to avoid duplicate generation of required shared resources

    # the Cython version of the model, instantiated on first request, which should be after the vocabulary was build.
    def getModelC(self):
        if not hasattr(self, 'modelc'):
            self.modelc = modelc(self)
        return self.modelc

# a thread that repeatedly pulls a chunk of input data from the queue and calls
# the trainer on that chunk, until there is no more input
# note must be a 
def learnThread(threadid, model, queue):
    def learn(input):
        model.pipe[threadid].feed(input)

    while True:
        try:
            input = queue.get(False)
            learn(input)
        except Empty:
            break


# C version of the model, to allow nogil Cython modules to process efficiently while accessing the model
# modelc only stores standard model parameters and references to the neural net solution, user defined
# model parameters can be taken from the py-model in the _init_ of a pipe module.
cdef class modelc:
    def __init__(self, m):
        self.model = m                                  # links back to the py-model
        self.progress = toIArray(m.progress)            # used to register progress per thread
        self.totalwords = m.vocab.total_words           # assumed to be the number of words to be processed (for progress)
        self.windowsize = m.windowsize
        self.vocsize = len(m.vocab)
        self.cores = m.cores
        self.alpha = m.alpha
        self.iterations = m.iterations
        self.sigmoidtable = self.createSigmoidTable()   # used for fast lookup of sigmoid function

    def getModel(self):
        return self.model

    def setSolution(self, solution):
        self.w = allocRP(len(solution))
        self.w_input = allocI(len(solution))
        self.w_output = allocI(len(solution))
        self.layer = allocRP(len(solution) * self.cores)
        for l in range(len(solution)):
            self.w[l] = toRArray(solution[l]);
            self.w_input[l] = solution[l].shape[0]
            self.w_output[l] = solution[l].shape[1]
        self.matrices = len(solution)

    # fast lookup table for sigmoid activation function
    cdef cREAL* createSigmoidTable(self):
        self.MAX_SIGMOID = 6
        self.SIGMOID_TABLE = 1000
        cdef cREAL* table = allocR(self.SIGMOID_TABLE)
        for i in range(self.SIGMOID_TABLE):
            e = math.exp(float32(2 * self.MAX_SIGMOID * i / self.SIGMOID_TABLE - self.MAX_SIGMOID))
            table[i] = e / float32(e + 1)
        return table

    # returns a thread-safe vector for the given layer, 0 being the input and |layer|-1 being the output layer
    # getLayer allows the layer to be shared over different pipe modules in the same thread
    cdef cREAL *getLayer(self, int thread, int layer) nogil:
        if self.layer[thread * self.cores + layer] == NULL:
            self.layer[thread * self.cores + layer] = self.createWorkLayer(layer)
        return self.layer[thread * self.cores + layer]

    # returns a thread-safe vector for the given layer, 0 being the input and |layer|-1 being the output layer
    # createLayer creates a non-shared layer instance
    cdef cREAL *createWorkLayer(self, int layer) nogil:
        size = self.getLayerSize(layer)
        return allocR(size)

    # returns the size of layer #layer
    cdef cINT getLayerSize(self, int layer) nogil:
        return self.w_input[layer] if layer < self.matrices else self.w_output[layer - 1]

    # returns a float that contains is the fraction of words processed, for reporting and to adjust the learning rate
    cdef float getProgress(self) nogil:
        cdef int s = 0
        for i in range(self.cores):
            s += self.progress[i]
        return s / float(self.totalwords)