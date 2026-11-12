# syna attestation bundles

Public hardware-attestation proofs (`.syna`, CBOR-framed) consumed by
the syna NixOS module. Not secrets; safe to commit.

## Refresh

Each bundle ages with the underlying cert chain. Re-export when:

- the device is re-provisioned (key regenerated)
- you rotate to a new attestation root
- a tripwire test in syna flags upcoming root expiry

## Producing a bundle

`fafnir` (jester):

```
syna export fafnir --socket /run/user/1000/fafnir/tpm-ops.sock --key <fingerprint> --out config/syna/attestations/jester-fafnir.syna
```

Replay before committing:

```
syna config/syna/attestations/jester-fafnir.syna
```

