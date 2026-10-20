# The mypkg package's greetings.

import mypkg;

[Test]
greets_by_name() {
    expect_equal(mypkg.greet("Ada"), "Hello, Ada!");
}
