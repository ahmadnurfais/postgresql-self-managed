# PostgreSQL TLS and mTLS explained

## Table of contents

- [DNS, ports, and TLS termination](#dns-ports-and-tls-termination)
- [Certbot, PostgreSQL, and Nginx](#certbot-postgresql-and-nginx)
- [Server verification and TLS authentication](#server-verification-and-tls-authentication)
- [Passwordless mTLS authentication](#passwordless-mtls-authentication)
- [Keys, certificates, and trust stores](#keys-certificates-and-trust-stores)
- [Browser errors on the database hostname](#browser-errors-on-the-database-hostname)
- [Expiry, renewal, and revocation](#expiry-renewal-and-revocation)
- [Verification checklist](#verification-checklist)
- [References](#references)

## DNS, ports, and TLS termination

DNS maps a name to an address. The application chooses the port and protocol. A DNS record
does not install a certificate, encrypt traffic, or choose the service that handles TLS.

```text
db.iyagi.cloud --DNS lookup--> database server public IP

Npgsql / psql --TCP 5432--> Docker port mapping --> PostgreSQL
Browser      --TCP 443--------------------------> Nginx, if listening
```

`PG_BIND_ADDRESS` selects the host interface for Docker's published database port.
`PG_APP_ALLOWED_CIDR` selects allowed connection sources. Behind NAT, PostgreSQL normally
sees the client's public egress address. These address rules supplement certificate and
role authentication; they do not identify a certificate holder by themselves.

With Cloudflare **DNS only**, Cloudflare answers DNS queries and database traffic goes
to the server. The standard orange-cloud HTTP proxy does not proxy PostgreSQL port 5432.
For a proxied website, Cloudflare can terminate browser TLS and establish a separate
origin connection. That is a different network path from this database deployment.

## Certbot, PostgreSQL, and Nginx

| Component | Responsibility |
| --- | --- |
| Let's Encrypt | Issue and sign the public server certificate after domain-control validation |
| Certbot | Obtain and renew certificates; run configured deployment hooks |
| Cloudflare DNS API | Allow DNS-01 validation through temporary TXT records |
| Nginx | Load configured certificate/key and terminate HTTPS on its listener |
| PostgreSQL | Load configured certificate/key and terminate PostgreSQL TLS on its listener |
| Docker port mapping | Forward TCP traffic to the container; no TLS termination in this stack |

```text
Certificate management:
Certbot --> Let's Encrypt / DNS validation --> files under /etc/letsencrypt
                                              |                    |
                                    Nginx config + reload    database deploy hook
                                                                   |
                                                    PG_TLS_DIR + PostgreSQL reload

Live connections:
Browser <-- HTTPS TLS --> Nginx <-- configured upstream protocol --> Web application
Backend <-- PostgreSQL TLS -------------------------------------> PostgreSQL
```

Certbot does not handle live database or website traffic. A certificate binds a public
key to an identity; it is not tied to port 443. The service must load an appropriate
certificate and possess the corresponding private key. PostgreSQL and Nginx configure
and reload their certificates independently, even on the same machine.

## Server verification and TLS authentication

For the repository's `PG_AUTH_MODE=tls` and client `SSL Mode=VerifyFull`:

1. The backend resolves `db.iyagi.cloud` and opens TCP port 5432.
2. With standard PostgreSQL SSL negotiation, the driver requests TLS before sending
   database credentials. Newer clients can support other negotiation modes; both peers
   must agree on the protocol.
3. PostgreSQL presents its server certificate and intermediate chain, and proves possession
   of its private key during the TLS handshake.
4. The backend verifies the chain to a trusted CA, validity dates, server usage, and that
   the certificate SAN matches the configured hostname `db.iyagi.cloud`.
5. The peers establish encrypted, integrity-protected session traffic. In modern TLS,
   session encryption uses negotiated symmetric keys; the certificate key authenticates
   the handshake. Private keys are not sent over the connection.
6. The backend sends the requested database and role through TLS. PostgreSQL selects the
   first matching HBA rule using connection type, source address, database, and role.
7. A `scram-sha-256` rule requires a SCRAM password proof. PostgreSQL checks it against
   the role's stored verifier and then enforces the role's database permissions.

TLS server identity validation and SCRAM database authentication answer separate questions:
which server accepted the connection, and which database role may the client use?

`VerifyFull` fails on unavailable TLS, an untrusted server issuer, or a hostname mismatch.
Npgsql `Require` mandates encryption without this server identity verification. Default
`Prefer` can accept plaintext, so it is insufficient as the client's security policy.

## Passwordless mTLS authentication

The repository's `mtls` mode adds client verification and uses PostgreSQL's `cert` method.

```text
Backend verifies PostgreSQL:
  server certificate --> server issuing chain --> backend's trusted roots
  certificate SAN must match db.iyagi.cloud

PostgreSQL verifies backend:
  client certificate --> client issuing chain --> configured client-ca.pem
  client proves possession of client.key
  certificate CN must match requested database role
```

During TLS, PostgreSQL requests a client certificate and validates its chain against
`ssl_ca_file`, including validity and client-authentication usage. The backend proves
possession of the client private key. A copied public client certificate alone is not
enough to authenticate.

After TLS negotiation, the `hostssl ... cert` rule enforces the certificate requirement
and matches its CN to the requested username. The repository uses direct CN matching;
PostgreSQL also supports identity maps for deployments that configure them.

No database password is required. `init.sh` sets the application role's password to `NULL`
in this mode. The username, allowed source address, database selection, and role permissions
still apply. `cert` is distinct from `scram-sha-256 clientcert=verify-full`, which would
require both a certificate and a password.

The private CA signs client identities; it does not approve each live connection.
PostgreSQL uses local trust files. A client CA can remain offline between issuance,
renewal, and revocation operations. No public CA is required for these client certificates.
The server can continue using a Let's Encrypt certificate issued by a different CA.

## Keys, certificates, and trust stores

| File | Location | Purpose |
| --- | --- | --- |
| `fullchain.pem` | Database | Public server certificate and intermediate chain |
| `privkey.pem` | Database | Secret proof of the server's identity |
| OS CA bundle or `Root Certificate` | Backend | Trust anchors for validating the server |
| `client.crt` | Backend | Public identity certificate signed by the client CA |
| `client.key` | Backend | Secret proof of the client's identity |
| `client-ca.pem` | Database | Public trust anchors for validating clients |
| CA signing key | CA administration machine | Secret authority to issue client certificates |
| Client CRL | Database, if configured | Signed list of revoked client certificate serials |

For a publicly trusted server certificate, Npgsql uses the backend OS trust store.
No custom server-CA file is needed if that store trusts the issuer. A containerized
backend uses its container's trust store and credential paths.

For `psql`, this Linux option specifies the local server-trust bundle explicitly:

```text
sslrootcert=/etc/ssl/certs/ca-certificates.crt
```

That file is not a private key and does not authenticate the client. mTLS additionally
requires `sslcert` and `sslkey`. See [the setup guide](MTLS-SETUP.md#verify-the-connection).

## Browser errors on the database hostname

Opening `https://db.iyagi.cloud` requests HTTPS on **443**. It does not contact PostgreSQL
on 5432. If Nginx has no matching HTTPS virtual host, it may present another virtual host's
certificate, causing a hostname error. Other possibilities include an expired certificate,
an incomplete chain, or a different endpoint selected by DNS/proxy configuration. The
browser error alone does not identify the cause.

Opening `https://db.iyagi.cloud:5432` also does not test PostgreSQL: a browser speaks HTTPS,
while the database expects the PostgreSQL protocol and its supported TLS negotiation.
A browser client certificate does not make it a PostgreSQL client.

Inspect the HTTPS endpoint from a machine with OpenSSL and an appropriate trust bundle:

```sh
openssl s_client -connect db.iyagi.cloud:443 -servername db.iyagi.cloud \
  -verify_hostname db.iyagi.cloud -verify_return_error \
  -CAfile /etc/ssl/certs/ca-certificates.crt </dev/null
```

Inspect the PostgreSQL TLS endpoint with its protocol negotiation and client credentials:

```sh
openssl s_client -starttls postgres -connect db.iyagi.cloud:5432 \
  -servername db.iyagi.cloud -verify_hostname db.iyagi.cloud -verify_return_error \
  -CAfile /etc/ssl/certs/ca-certificates.crt \
  -cert "$HOME/postgres-client/client.crt" -key "$HOME/postgres-client/client.key" </dev/null
```

This inspects the handshake and server certificate; it does not prove database-role
authentication. Use `psql` or Npgsql for the complete database connection test.
Configuring an HTTPS site for the database hostname is optional and separate from
PostgreSQL TLS. A working database endpoint need not display a page in a browser.

## Expiry, renewal, and revocation

| Mechanism | Meaning |
| --- | --- |
| Certificate expiry | End of the certificate's validity window |
| Certificate renewal | Issue and deploy a replacement certificate |
| Revocation | Cancel a certificate before its expiry, such as after key theft |
| CRL `nextUpdate` | Deadline for refreshing the signed revocation snapshot |

PostgreSQL consults a client CRL only when configured. Disabling CRL checking does not
disable certificate expiry checks. With CRL checking disabled, an otherwise valid revoked
client certificate can still authenticate. Revocation must reach the database through
a deployed, current CRL to take effect for new connections.

Certbot renews the public server certificate. A host deployment hook updates PostgreSQL's
copies and reloads it. The private client CA, client certificates, and CRLs have their own
renewal procedures. Client CRL settings do not configure the backend's revocation policy
for server certificates; Npgsql has a separate `Check Certificate Revocation` option.

Expiry, HBA changes, and CRL reloads do not end existing database sessions. Test fresh
connections after changes; terminate affected sessions when immediate revocation is required.

## Verification checklist

- `VerifyFull` connection succeeds with the intended hostname and trusted server issuer.
- `pg_stat_ssl` reports TLS and, in mTLS mode, the expected client DN and serial.
- Plaintext connections fail.
- mTLS connections without a certificate or with an untrusted/wrong-role certificate fail.
- A denied source address fails even with valid credentials.
- With CRL checking enabled, a revoked client fails and a non-revoked client succeeds.
- Renewal deployment serves the replacement certificate on a fresh connection.

The Docker healthcheck uses local `peer` authentication. A healthy container does not
prove remote firewall access, certificate trust, or application authentication.

## References

- [PostgreSQL TLS](https://www.postgresql.org/docs/18/ssl-tcp.html)
- [PostgreSQL certificate authentication](https://www.postgresql.org/docs/18/auth-cert.html)
- [Npgsql security](https://www.npgsql.org/doc/security.html)
- [Certbot renewal](https://eff-certbot.readthedocs.io/en/stable/using.html#renewing-certificates)
- [Self-managed client CA setup](MTLS-SETUP.md)
