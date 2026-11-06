# License document

`LICENSES.txt` is the offline source-install catalog displayed in the app. It contains the project MIT license, model licenses, optional integrations, Node.js and CPython notices, and the full license files from the dependency payload. It includes platform-specific optional components.

The package build regenerates `Contents/Resources/OPEN_SOURCE_LICENSES.txt` from its actual Node/Python payload before signing, so Intel and Apple Silicon each list their bundled components. Generation fails if a dependency has no license file or a version-specific upstream fallback.

After changing dependencies, regenerate the source catalog from a fresh Apple Silicon package payload:

```sh
python3 scripts/generate-license-notices.py \
  --project-root . \
  --resources build/package-arm64/root/Applications/SpeekCoding.app/Contents/Resources \
  --output licenses/LICENSES.txt
```

`catalog.json` records upstream sources and scope for the separately downloaded weights, integrations, and the few wheels that omit their license files. `upstream/` holds those license texts with UTF-8 encoding and normalized line endings. Preserve copyright notices and verify replacements against the named upstream version. Node.js and Python include additional embedded-library notices; the generator reproduces those runtime documents in full.
