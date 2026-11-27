# Fauxroku Worker Dynos

The worker process of a Fauxroku app: the same image as the web dynos, with no address, for background jobs. It gets the same variables as the web dynos with `PROCESS_TYPE=worker`, so one entrypoint can start either process.

Leave **Subdomain** empty. Workers don't need to run all the time: on **Spot** they cost about 70% less, and AWS replacing one only delays the queue.
