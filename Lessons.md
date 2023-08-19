## Lessons from working with GenServer

1. If you plan to start multiple instances of a GenServer e.g. Client,
   no need to assign a name. If you do, only 1 such process will be started with the name.
   Trying to create new ones will fail with the error `{:error, {:already_started, pid}}`

## Biggest Pain Points

- Sockets and TCP - Send / Receive Handshake


## Docs

`info_hash` -> The 20 byte sha1 hash of the bencoded form of the info value from the metainfo file.

> The info-hash must be the hash of the encoded form as found in the .torrent file, which is identical to bdecoding the metainfo file, extracting the info dictionary and encoding it if and only if the bdecoder fully validated the input (e.g. key ordering, absence of leading zeros).
