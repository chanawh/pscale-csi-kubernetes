# OneFS setup for the CSI driver

Run this on the OneFS Simulator virtual node, as root, before
installing the driver. It is the same node as Project 1, the
NAS-to-AWS migration, cluster `nas2aws-onefs`, host 192.168.1.50.

## 1. Base path

```sh
mkdir -p /ifs/data/csi
chmod 777 /ifs/data/csi
```

The driver creates one directory per volume under here, for
example `/ifs/data/csi/pvc-xxx`. If this path does not exist,
volume creation fails.

## 2. SmartQuotas

```sh
isi quota quotas create --path=/ifs/data/csi --type=directory \
  --hard-threshold=100G --enforced=yes
```

The driver sets a quota per volume when `enableQuota: true`
is set in `helm/values.yaml`. SmartQuotas must be enabled on
the cluster, or that step fails. Without quotas, nothing stops
a volume growing past its PVC size.

## 3. NFS

The driver uses NFS only. No SMB, no block.

```sh
isi nfs exports create --paths=/ifs/data/csi --clients=192.168.1.0/24
isi services nfs enable
```

## 4. Access zone

System is the default zone, and is what the StorageClass uses.
A per-tenant zone would be a different StorageClass with
`AccessZone: zone1`, not a different driver.

## 5. Networking, the step that breaks most first attempts

kind nodes are Docker containers on a bridge network. They
must be able to reach OneFS on the host LAN, on ports 445
(NFS) and 8080 (Platform API). If the OneFS IP is on a
different subnet from the Docker bridge, the driver pods
will fail to probe the cluster. Fix it by putting OneFS on
a network the Docker bridge can route to, or by running
kind with host networking, or by running the cluster on
EKS with a VPC that can route to OneFS. Do not use NAT
or Host-only networking for the OneFS VM; use Bridged,
as in Project 1.

## 6. Credentials

Create a user for the driver, or use root in the lab only.
The secret is `helm/isilon-creds.yaml`, created from
`helm/isilon-creds.yaml.example`. Never commit the filled-in
file. The driver reads `clusterName`, `endpoint`,
`endpointPort`, `user`, `password`, `skipCertificateValidation`,
`isiPath`, and `isiAccessZone` from that secret.
