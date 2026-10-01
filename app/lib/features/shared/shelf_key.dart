/// How a shelf sorts a name: by its letters, not its case, and without a
/// leading "The ", so "The Night Sky Cast" files under N as people look
/// for it.
String shelfKey(String name) {
  final lower = name.trim().toLowerCase();
  return lower.startsWith('the ') ? lower.substring(4).trimLeft() : lower;
}
