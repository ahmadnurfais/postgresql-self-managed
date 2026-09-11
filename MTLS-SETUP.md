# mTLS setup with a self-managed client CA

OpenSSL 3 procedure for a small, manually managed client CA. Example database hostname:
`db.iyagi.cloud`. Substitute deployment paths, SSH addresses, and database roles as needed.

## Table of contents

- [Prerequisites and file ownership](#prerequisites-and-file-ownership)
- [Create the client CA](#create-the-client-ca)
- [Issue a client certificate](#issue-a-client-certificate)
- [Deploy and enable mTLS](#deploy-and-enable-mtls)
- [Verify the connection](#verify-the-connection)
- [Renew client certificates](#renew-client-certificates)
- [Revoke certificates and refresh CRLs](#revoke-certificates-and-refresh-crls)
- [Renew or rotate the CA](#renew-or-rotate-the-ca)
- [Server certificate renewal](#server-certificate-renewal)
- [References](#references)

## Prerequisites and file ownership

The database already has a trusted server certificate covering `db.iyagi.cloud`, DNS-only
resolution to its reachable address, and restricted network access. The database host
provides `fullchain.pem` and `privkey.pem` under `/opt/databases/tls/db.iyagi.cloud`.
Certificate issuance and file deployment are external to `init.sh`.

| Machine | Contents |
| --- | --- |
| CA administration machine | Encrypted CA key, CA certificate, issuance database, CRLs, protected backups |
| Backend | Its own private key and signed client certificate |
| Database server | Server key/certificate, public client CA certificate, optional CRL |

Keep CA signing keys outside database and backend deployments. A CA service does not need
to run during connections. Use one key/certificate pair per consumer. This guide uses
`app_user` as the client CN; substitute the actual `PG_APP_USER` throughout.

## Create the client CA

**CA machine, as a normal user.** Run initialization once in a new directory. Stop if the
directory exists; never reset an established CA's index or serial files.

```sh
umask 077
mkdir -m 700 ~/postgres-client-ca
cd ~/postgres-client-ca
mkdir -m 700 private certs newcerts csr crl
touch index.txt
printf '1000\n' > serial
printf '1000\n' > crlnumber
nano openssl.cnf
```

Save this configuration:

```ini
[ ca ]
default_ca = client_ca

[ client_ca ]
dir = .
database = $dir/index.txt
new_certs_dir = $dir/newcerts
certificate = $dir/certs/client-ca.pem
private_key = $dir/private/client-ca.key
serial = $dir/serial
crlnumber = $dir/crlnumber
default_md = sha256
default_days = 90
default_crl_days = 30
policy = client_policy
x509_extensions = client_cert
crl_extensions = crl_ext
unique_subject = no
copy_extensions = none

[ client_policy ]
commonName = supplied

[ req ]
prompt = no
distinguished_name = ca_name
x509_extensions = ca_cert
default_md = sha256

[ ca_name ]
CN = PostgreSQL Client Root CA

[ ca_cert ]
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always

[ client_cert ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always

[ crl_ext ]
authorityKeyIdentifier = keyid:always
```

Run CA commands from this directory: paths in `openssl.cnf` are relative.
The profile permits direct client issuance, with no intermediate CAs. Repeated subjects
permit overlapping renewals. The CA controls extensions rather than copying CSR extensions.

```sh
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
  -aes-256-cbc -out private/client-ca.key
openssl req -new -x509 -config openssl.cnf -key private/client-ca.key \
  -sha256 -days 1825 -out certs/client-ca.pem
openssl ca -config openssl.cnf -gencrl -out crl/client-ca.crl.pem
```

Enter the CA key passphrase at the prompts. Store it separately from a protected backup
of the whole CA directory. Back up issuance records after signing and revocation operations.
`openssl ca` updates local `index.txt`, `serial`, and `newcerts/`, not PostgreSQL.

```sh
openssl verify -check_ss_sig -CAfile certs/client-ca.pem certs/client-ca.pem
openssl x509 -in certs/client-ca.pem -noout -subject -issuer -dates
openssl x509 -in certs/client-ca.pem -noout -ext basicConstraints,keyUsage
openssl crl -in crl/client-ca.crl.pem -noout -issuer -lastupdate -nextupdate
```

Expect `OK`, `CA:TRUE, pathlen:0`, and certificate/CRL signing usage.

## Issue a client certificate

**Backend.** Use a new directory; preserve existing credentials during renewals.

```sh
umask 077
mkdir -m 700 ~/postgres-client
cd ~/postgres-client
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out client.key
chmod 600 client.key
openssl req -new -sha256 -key client.key -subj '/CN=app_user' -out client.csr
openssl req -in client.csr -noout -verify -subject
scp client.csr CA_USER@CA_HOST:~/postgres-client-ca/csr/backend-01.csr
```

Replace uppercase SSH placeholders before execution. The client key is unencrypted for
unattended startup; restrict access to the application identity. Transfer only the CSR.

**CA machine.** Review the requested CN against the authorized database role, then sign:

```sh
cd ~/postgres-client-ca
openssl req -in csr/backend-01.csr -noout -verify -subject
openssl ca -config openssl.cnf -extensions client_cert -days 90 -notext \
  -in csr/backend-01.csr -out certs/backend-01.crt
openssl verify -purpose sslclient -CAfile certs/client-ca.pem certs/backend-01.crt
openssl x509 -in certs/backend-01.crt -noout -subject -issuer -serial -dates
openssl x509 -in certs/backend-01.crt -noout -ext basicConstraints,keyUsage,extendedKeyUsage
scp certs/backend-01.crt BACKEND_USER@BACKEND_HOST:~/postgres-client/client.crt
```

Expect `OK`, the intended CN, `CA:FALSE`, `Digital Signature`, and `TLS Web Client Authentication`.

**Backend.** Compare public-key hashes; they must match:

```sh
openssl pkey -in ~/postgres-client/client.key -pubout | openssl dgst -sha256
openssl x509 -in ~/postgres-client/client.crt -pubkey -noout | openssl dgst -sha256
```

## Deploy and enable mTLS

**CA machine.** Send the public CA certificate to the database host:

```sh
scp ~/postgres-client-ca/certs/client-ca.pem root@db.iyagi.cloud:/root/client-ca.pem
```

**Database host.** Stage then replace the file inside the existing mounted directory:

```sh
sudo install -o root -g root -m 644 /root/client-ca.pem \
  /opt/databases/tls/db.iyagi.cloud/client-ca.pem.new
sudo mv /opt/databases/tls/db.iyagi.cloud/client-ca.pem.new \
  /opt/databases/tls/db.iyagi.cloud/client-ca.pem
```

In the deployment repository's `.env`:

```dotenv
PG_AUTH_MODE=mtls
PG_TLS_DIR=/opt/databases/tls/db.iyagi.cloud
PG_CLIENT_CRL_FILE=
PG_APP_USER=app_user
PG_APP_DB=app_db
```

Keep the appropriate `PG_BIND_ADDRESS`, `PG_APP_ALLOWED_CIDR`, and `POSTGRES_PASSWORD`.
Run from that repository:

```sh
sudo ./init.sh
docker exec -u postgres postgres psql -d postgres -c 'SHOW ssl_ca_file;'
docker exec -u postgres postgres psql -d postgres -c \
  'SELECT type, database, user_name, address, auth_method, error FROM pg_hba_file_rules;'
```

Expect `hostssl` application rules using `cert` and empty error fields. `init.sh` clears
the application password, regenerates configuration, and may recreate the container when
mounts or the image change. See [authentication modes](README.md#authentication-modes).

## Verify the connection

**Ubuntu/Debian backend.** Substitute the database and role names:

```sh
psql "host=db.iyagi.cloud port=5432 dbname=app_db user=app_user sslmode=verify-full sslrootcert=/etc/ssl/certs/ca-certificates.crt sslcert=$HOME/postgres-client/client.crt sslkey=$HOME/postgres-client/client.key connect_timeout=10" -w
```

```sql
SELECT current_user, inet_client_addr(), ssl, version, client_dn, client_serial, issuer_dn
FROM pg_stat_ssl WHERE pid = pg_backend_pid();
```

Expect TLS, the matching client CN, and the issuing client CA. Exit with `\q`.
Repeat with `sslcert=/nonexistent/client.crt sslkey=/nonexistent/client.key` to verify
missing-client rejection, and with `sslmode=disable` to verify plaintext rejection.
Lowercase `-w` prevents database password prompts; uppercase `-W` forces one.

Npgsql, with paths inside the application runtime:

```text
Host=db.iyagi.cloud;Port=5432;Database=app_db;Username=app_user;SSL Mode=VerifyFull;SSL Certificate=/app/certs/client.crt;SSL Key=/app/certs/client.key
```

The backend trusts the server issuer through its OS trust store. A private server issuer
requires an appropriate `Root Certificate` or OS trust installation. The client CA need
not be the server issuer. No application database password is required.

## Renew client certificates

Renewal issues a replacement; it does not extend the existing certificate. For this
90-day profile, schedule renewal at least 30 days before expiry. Check dates with
`openssl x509 -in client.crt -noout -dates`.

1. On the backend, repeat key/CSR generation in `~/postgres-client-next`, using the same
   authorized CN. Transfer the CSR under a new name, such as `backend-01-next.csr`.
2. On the CA machine, sign it to `certs/backend-01-next.crt` using the issuance commands.
   Keep the existing CA database and serial files. The issuing CA must remain valid
   throughout the new certificate's intended lifetime; shorten `-days` or rotate the CA.
3. Return the signed certificate to `~/postgres-client-next/client.crt`. Compare key hashes
   and test a new `psql` connection with the `postgres-client-next` paths before switching.
4. Point the application at the new pair. Recreate its data source or restart the application
   as required by its credential-loading behavior. Verify a new connection and serial number.
5. Retire the old key after consumers have migrated. Revoke and publish the old certificate's
   serial if it must stop authenticating before expiry. Keep its public certificate in CA records.

No PostgreSQL reload is needed for a new client certificate under the same trusted CA and
role. Existing pooled sessions continue using their established authentication. Fresh
connections are required to prove the replacement works.

## Revoke certificates and refresh CRLs

**CA machine.** For a compromised client key, revoke its certificate:

```sh
cd ~/postgres-client-ca
openssl ca -config openssl.cnf -revoke certs/backend-01.crt -crl_reason keyCompromise
```

For planned credential replacement, use `-crl_reason superseded`. Revocation is permanent
for that certificate. Generate and publish a new CRL after each revocation, and before
`nextUpdate` even when there are no revocations. The profile's CRL lifetime is 30 days;
a weekly refresh provides margin.

```sh
openssl ca -config openssl.cnf -gencrl -out crl/client-ca.crl.pem
openssl crl -in crl/client-ca.crl.pem -noout -verify -CAfile certs/client-ca.pem
openssl crl -in crl/client-ca.crl.pem -noout -lastupdate -nextupdate
scp crl/client-ca.crl.pem root@db.iyagi.cloud:/root/client-ca.crl.pem
```

**Database host.**

```sh
sudo install -o root -g root -m 644 /root/client-ca.crl.pem \
  /opt/databases/tls/db.iyagi.cloud/client-ca.crl.pem.new
sudo mv /opt/databases/tls/db.iyagi.cloud/client-ca.crl.pem.new \
  /opt/databases/tls/db.iyagi.cloud/client-ca.crl.pem
```

For first activation, set `PG_CLIENT_CRL_FILE=client-ca.crl.pem` in `.env` and run `init.sh`.
For later file refreshes, reload:

```sh
docker exec -u postgres postgres psql -d postgres -c 'SELECT pg_reload_conf();'
docker logs --since=2m postgres
```

Check both revoked-client rejection and non-revoked-client success on new connections.
PostgreSQL reads the deployed CRL; it does not contact this CA for updates. An expired CRL
can block valid clients. Disabling CRL checking leaves certificate expiry checks active.
Neither CRL publication nor certificate expiry terminates existing sessions; immediate
revocation also requires terminating the affected database sessions.

## Renew or rotate the CA

Use a replacement CA and a trust overlap before the existing CA expires. This procedure
rotates both the CA key and certificate; it does not rewrite the old CA certificate or
make already expired client chains valid.

1. Repeat [CA creation](#create-the-client-ca) in a new `~/postgres-client-ca-v2` directory.
   Use `CN = PostgreSQL Client Root CA v2`. Preserve the old directory and its records.
2. On the CA machine, create a public trust bundle containing both CAs:

   ```sh
   cat ~/postgres-client-ca/certs/client-ca.pem \
     ~/postgres-client-ca-v2/certs/client-ca.pem > ~/client-ca-bundle.pem
   scp ~/client-ca-bundle.pem root@db.iyagi.cloud:/root/client-ca.pem
   ```

3. Deploy that bundle as `client-ca.pem` using the staging commands above. If CRL checking
   is enabled, refresh both CAs' CRLs and deploy a bundle under the configured CRL filename:

   ```sh
   cat ~/postgres-client-ca/crl/client-ca.crl.pem \
     ~/postgres-client-ca-v2/crl/client-ca.crl.pem > ~/client-crl-bundle.pem
   scp ~/client-crl-bundle.pem root@db.iyagi.cloud:/root/client-ca.crl.pem
   ```

   Stage both bundles before requesting a PostgreSQL reload. Check logs and new connections.
4. Issue replacement client certificates from the v2 CA, with new client keys and the same
   role CNs. Migrate each backend using the client renewal procedure. During the overlap,
   PostgreSQL accepts valid client chains from either trusted CA.
5. After all consumers migrate, deploy only the v2 CA certificate as `client-ca.pem` and
   only its current CRL if enabled. Reload and verify new-CA success and old-CA rejection.
6. Retain protected historical issuance/revocation records. Retire the old signing key
   according to the deployment's key-retention policy.

No server certificate replacement is required: the client CA and server CA are independent.
A compromised CA key requires prompt removal of that CA's trust and replacement of affected
credentials rather than a normal extended overlap. Existing sessions require separate handling.

## Server certificate renewal

Certbot manages the Let's Encrypt server certificate independently of this private CA.
The host-managed deployment hook must copy renewed `fullchain.pem` and `privkey.pem` into
the mounted directory, preserve permissions, and reload PostgreSQL. Nginx reloads do not
reload PostgreSQL. Test the installed hook with:

```sh
sudo certbot renew --cert-name db.iyagi.cloud --dry-run --run-deploy-hooks
```

This requires an existing Certbot deployment hook; the command alone does not install one.
Certbot uses the current production certificate for dry-run deployment hooks. Confirm a
fresh verified client connection and the served certificate's expiry after deployment.
Certbot does not renew the private client CA, client certificates, or CRLs in this guide.

## References

- [OpenSSL CA command](https://docs.openssl.org/3.0/man1/openssl-ca/)
- [PostgreSQL certificate authentication](https://www.postgresql.org/docs/18/auth-cert.html)
- [PostgreSQL TLS configuration](https://www.postgresql.org/docs/18/ssl-tcp.html)
- [TLS and mTLS explained](TLS-MTLS-EXPLAINED.md)
