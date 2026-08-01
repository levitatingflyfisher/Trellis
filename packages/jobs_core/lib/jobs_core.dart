/// The checkpointed-job engine (proposal-2 §9): job rows, the chunk
/// protocol, the resume laws, bounded backoff, honest ETA. Pure Dart —
/// platform executors (Drift transactions, foreground services) are
/// adapter concerns in the app.
library;

export 'src/backoff.dart';
export 'src/chunked_task.dart';
export 'src/eta.dart';
export 'src/job.dart';
export 'src/job_store.dart';
export 'src/runner.dart';
