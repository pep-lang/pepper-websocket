# pepper-mypkg

One paragraph for [Pepper](https://github.com/pep-lang/pepper): what the
package does and why someone would use it.

One module, **`mypkg`**:

- **`mypkg.greet(name)`** returns a greeting for `name`.

```pepper
import mypkg;

main(): int {
    print(mypkg.greet("Ada"));   # Hello, Ada!
    return 0;
}
```

## Limits

- What it does not do yet.

## Using it

This repository is a package: `pep.toml` marks its root, and its root
`module.pep` is the `mypkg` module. Add it to a project under the name
`mypkg`:

```sh
pepper package add OWNER/pepper-mypkg --name mypkg
```

which writes

```toml
[dependencies]
mypkg = { github = "OWNER/pepper-mypkg" }
```

Without a project, put a folder named `mypkg` that holds (or links to)
this repository on the import path: `pepper build -I packages main.pep`.

## Tests

```sh
tests/run.sh path/to/pepper
```

runs the `[Test]` functions in `tests/` with `pepper test`.

## Releasing

CI (`.github/workflows/ci.yml`) runs the tests on Linux, macOS and
Windows for every push to `main` and every pull request. To release, set
`version` in `pep.toml`, merge, then push the matching tag
(`git tag v1.0.0 && git push origin v1.0.0`): CI tests the tag and
publishes a GitHub release for it. `pepper package add` and `pepper
package update` find versions by their tags.

## License

Apache-2.0; see [LICENSE](LICENSE).
