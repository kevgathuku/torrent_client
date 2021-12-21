## Lessons from working with GenServer

1. If you plan to start multiple instances of a GenServer e.g. Client,
   no need to assign a name. If you do, only 1 such process will be started with the name.
   Trying to create new ones will fail with the error `{:error, {:already_started, pid}}`
