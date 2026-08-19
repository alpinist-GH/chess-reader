# ONNX Runtime's native JNI code looks up these classes and methods by their
# original names. R8 cannot see those native references, so a minimized build
# otherwise renames/removes them and aborts on the first inference call.
-keep class ai.onnxruntime.** { *; }
