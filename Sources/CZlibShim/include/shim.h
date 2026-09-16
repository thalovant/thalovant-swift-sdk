/* zlib, reached through a shim so the module map does not have to name an
   absolute header path: on macOS zlib.h lives in the SDK, on Linux in
   /usr/include, and both resolve this include the same way. */
#include <zlib.h>
