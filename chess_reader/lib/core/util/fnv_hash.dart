/// 64-bit FNV-1a over [bytes], masked to 53 bits (an exact int everywhere),
/// as a hex string. Not cryptographic — just a fast, stable key that changes
/// whenever the input bytes change. Used to key extracted ONNX models by
/// content and conversion-cache files by source path.
String fnv1aHex(List<int> bytes) {
  var hash = 0xcbf29ce484222325;
  const prime = 0x100000001b3;
  for (final b in bytes) {
    hash = (hash ^ b) * prime;
  }
  return (hash & 0x1fffffffffffff).toRadixString(16);
}
