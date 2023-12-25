const nt = require("nt");
const path = require("path");

const rootDir = path.resolve(__dirname, '..')
const multiFiletorrent = path.join(
  rootDir,
  "test",
  "_data",
  "big-buck-bunny.torrent"
);
const singleFiletorrent = path.join(
  rootDir,
  "test",
  "_data",
  "debian-12.1.0-amd64-netinst.iso.torrent"
);

console.log(`Single Path: ${singleFiletorrent}`);
console.log(`Multi Path: ${multiFiletorrent}`);

// nt.read(singleFiletorrent, (err, torrent) => {
//   if (err) throw err;
//   console.log("Torrent Info keys:", Object.keys(torrent.metadata.info));
//   console.log("Torrent Info:", torrent.metadata.info);
//   console.log("Single File Info hash:", torrent.infoHash());
// });

nt.read(multiFiletorrent, (err, torrent) => {
  if (err) throw err;
  console.log("Torrent Info keys:", Object.keys(torrent.metadata.info));
  console.log("Multi File Info:", torrent.metadata.info);
  console.log("Multi File Info hash:", torrent.infoHash());
});
