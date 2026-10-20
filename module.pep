## One sentence saying what the module does, then what a caller needs to
## know before using it.
##
## Bring it in with `import mypkg`.
##
## - `greet`: what each part of the API is for
##
## @example
##     import mypkg;
##
##     main(): int {
##         print(mypkg.greet("Ada"));   # Hello, Ada!
##         return 0;
##     }

# This file only gathers the module's public API from its other files.

import "greet";

export greet;
