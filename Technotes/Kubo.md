# Kubo

## 20240415

go-ipfs, also known as [Kubo](https://github.com/ipfs/kubo), is a core component of Planet. We should always ship the latest version of Kubo with Planet.

There was an issue with IPNS starting from Kubo version 0.16, so we stayed at version 0.15.

https://discuss.ipfs.tech/t/ipfs-name-resolve-does-not-always-return-the-freshest-cid-for-ipns-on-kubo-0-20-0/16624

Now that Kubo has reached version 0.28, I think we should give this version another try.

## 20260505 IPNS publishing with copied keys

Planet currently publishes planet IPNS records through the Kubo HTTP API `name/publish` command with:

- `allow-offline=1`
- `key=<planet UUID>`
- `lifetime=7200h`
- no explicit `ttl`
- no explicit `sequence`

This works for a single writer, but it is fragile when the same IPNS private key is copied to more than one machine. IPNS is not a last-write-wins system. Records are ordered by signature version, then by monotonically increasing sequence number, then by validity time. The DHT rejects an incoming record when it already has a better record, so a publish call can appear successful locally while the wider network keeps returning an older CID that has a higher sequence number.

Kubo 0.15.0 automatically derives the next sequence from the local IPNS record in the node datastore. It only queries routing when no local record exists. Copying the private key does not copy that local IPNS record state, so each machine can advance sequence numbers independently. Planet's scheduled keepalive can make this more confusing by re-publishing `lastPublishedCID` every 600 seconds from whichever machine is running.

Kubo 0.41.0 keeps the same core IPNS ordering rule, but adds useful tools:

- `ipfs name publish --sequence=<n>` lets callers set an explicit sequence number. Kubo validates that it is greater than the current record sequence it knows about.
- `ipfs name get <name>` retrieves the signed raw IPNS record from routing.
- `ipfs name inspect` shows the record value, sequence, TTL, validity, and signature type.
- `ipfs name put <name> <record>` republishes a pre-signed IPNS record for cross-node sync or backup/restore.
- `--allow-delegated` and `Ipns.DelegatedPublishers` can publish IPNS over HTTP delegated routing when DHT connectivity is poor.
- The default IPNS record TTL in Kubo 0.41.0 is 5 minutes, and the default record lifetime is 48 hours. Planet still overrides lifetime with `7200h`.

The important conclusion is that upgrading Kubo alone does not make copied-key multi-writer publishing reliable. The fix should make Planet sequence-aware.

Recommended publishing flow for Kubo 0.41.0 or later:

1. Before publishing a new CID, fetch the best current network record for the planet IPNS name.
2. Inspect or parse the record sequence.
3. Publish the new CID with `sequence = currentSequence + 1`.
4. Use a shorter `ttl`, such as `1m`, for Planet records that should update quickly.
5. Enable `Ipns.UsePubsub` and consider delegated publishers for propagation, but treat them as transport improvements rather than conflict resolution.

If the network record cannot be fetched, Planet should avoid blindly publishing from sequence `0` on a copied key. A conservative fallback is to surface a retryable warning, or require an explicit recovery path that chooses a sequence above the last known Planet-persisted sequence.

## General Risks When Upgrading Kubo

There is a repository migration step involved when upgrading Kubo. To test the upgrade, perform it in a development environment with disposable data, or ensure the data is fully backed up before testing.

## How to Back Up IPFS Data in Planet

IPFS repo location:

```
~/Library/Containers/xyz.planetable.Planet/Data/Library/Application Support/ipfs
```

The process could be slow because there are many small files in the repo.

## git-lfs

The two binaries of Kubo are tracked with [git-lfs](https://git-lfs.com/). Ensure they are added with git-lfs before pushing a commit.
