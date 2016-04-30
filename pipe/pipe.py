# A Pipe is a lightweight module that performs a processing task on the input and
# optionally adds tasks to the processing queue for processing by the next Pipe in the pipeline.
# A Pipe extension must implement a feed(self, input) method
class Pipe:
    def __init__(self, pipeid, learner):
        self.learner = learner
        self.model = learner.model
        self.pipeid = pipeid
        self.solution = self.model.getSolution()

    def feed(self, threadid, task):
        raise NotImplementedError("A Pipe must implement the feed(threadid, task) method.")

    def build(self):
        pass

    # allows a Pipe to transform itself, based on the model's configuration it can
    # return None to remove itself from the Pipeline
    # return another Pipe instance to serve in its place
    def transform(self):
        return self

    def getTaskids(self, task):
        if self.model.split == 0 or task.iteration == 0:
            return self.model.tasks
        return self.model.tasks - self.solution.singletaskids

    def addTask(self, task):
        self.learner.addTask(task)

