# Byte fidelity: raw binaries, exact-bytes info hash

Bencode strings are raw binary byte strings, never UTF-8 text — filenames and
hashes are not necessarily valid UTF-8, so never `String`-validate or
`String`-manipulate them. Consequently the info hash is computed over the info
dictionary's exact original bytes sliced from the `.torrent` file, never by
decode-then-re-encode.

## Considered Options

- **Decode → re-encode for hashing**: rejected — re-encoding may reorder
  dictionary keys and silently produce a wrong identity hash.
- **UTF-8 treatment of torrent strings**: rejected — non-UTF-8 bytes in
  filenames and pieces corrupt on round-trip.
