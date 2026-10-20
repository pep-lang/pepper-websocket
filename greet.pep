## Greetings: `greet`.

## Returns a greeting for `name`.
##
## @param name who to greet
## @returns `Hello, <name>!`
## @example
##     mypkg.greet("Ada");   # "Hello, Ada!"
export greet(name: String): String {
    return $"Hello, {name}!";
}
