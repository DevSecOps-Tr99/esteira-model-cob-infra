#!/usr/bin/env python3
"""estm-submit - "submissao" de JCL no servidor de destino da POC.

Instalado em /usr/local/bin/estm-submit pelo cloud-init (main.bicep).
Faz no servidor o papel que, na Fase 2, sera do z/OSMF (docs/integracao-zos.md):

1. le o token apresentado pela esteira no stdin;
2. busca o token esperado no mesmo Key Vault, com a managed identity da VM,
   e compara - sem token valido, nada e "submetido" (rc 3);
3. confere que o usuario SSH so publica no proprio ambiente
   (estmtu -> TU, estmti -> TI, estmprd -> PRD) (rc 4);
4. grava o JCL como membro da "biblioteca" do ambiente
   (/srv/estm/<ENV>/<BIBLIOTECA>/<MEMBRO>), gera JOBID e um spool no
   formato JES2 e devolve tudo em JSON no stdout.

So usa a biblioteca padrao do Python 3.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import hmac
import json
import os
import pwd
import re
import shutil
import sys
import urllib.request

CONF_PATH = "/etc/estm/ambientes.json"
STATE_DIR = "/var/lib/estm"
BASE_DIR = "/srv/estm"
IMDS_TOKEN_URL = (
    "http://169.254.169.254/metadata/identity/oauth2/token"
    "?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net"
)


def fail(code: int, message: str) -> None:
    audit(f"RECUSADO rc={code} {message}")
    print(json.dumps({"erro": message}), file=sys.stderr)
    sys.exit(code)


def audit(message: str) -> None:
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    user = pwd.getpwuid(os.getuid()).pw_name
    try:
        with open(os.path.join(STATE_DIR, "auditoria.log"), "a", encoding="utf-8") as handle:
            handle.write(f"{stamp} {user} {message}\n")
    except OSError:
        pass


def kv_secret(vault: str, name: str) -> str:
    req = urllib.request.Request(IMDS_TOKEN_URL, headers={"Metadata": "true"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        access_token = json.load(resp)["access_token"]
    req = urllib.request.Request(
        f"https://{vault}.vault.azure.net/secrets/{name}?api-version=7.4",
        headers={"Authorization": f"Bearer {access_token}"},
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.load(resp)["value"]


def next_jobid() -> str:
    path = os.path.join(STATE_DIR, "jobseq")
    with open(path, "a+", encoding="utf-8") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        handle.seek(0)
        current = int(handle.read().strip() or "0") + 1
        handle.seek(0)
        handle.truncate()
        handle.write(str(current))
    return f"JOB{current:05d}"


def build_spool(jobid: str, jobname: str, user: str, steps: list[tuple[str, str]]) -> str:
    now = dt.datetime.now(dt.timezone.utc)
    hhmmss = now.strftime("%H.%M.%S")
    lines = [
        "                    J E S 2  J O B  L O G  --  S Y S T E M  E S T M",
        "",
        f"{hhmmss} {jobid}  IRR010I  USERID {user.upper():<8} IS ASSIGNED TO THIS JOB.",
        f"{hhmmss} {jobid}  $HASP373 {jobname:<8} STARTED - INIT 1    - CLASS A - SYS ESTM",
    ]
    for step, pgm in steps:
        lines.append(f"{hhmmss} {jobid}  IEF142I {jobname} {step} - STEP WAS EXECUTED - COND CODE 0000")
        lines.append(f"{hhmmss} {jobid}  IEF373I STEP/{step:<8}/START {now:%Y%j.%H%M}  PGM={pgm}")
        lines.append(f"{hhmmss} {jobid}  IEF374I STEP/{step:<8}/STOP  {now:%Y%j.%H%M}")
    lines.append(f"{hhmmss} {jobid}  $HASP395 {jobname:<8} ENDED - RC=0000")
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(prog="estm-submit")
    parser.add_argument("--env", required=True)
    parser.add_argument("--library", required=True)
    parser.add_argument("--member", required=True)
    parser.add_argument("file")
    args = parser.parse_args()

    # /var/lib/estm e compartilhado pelos tres usuarios (grupo estm): a
    # sequencia de JOBID e a auditoria precisam continuar gravaveis pelo grupo.
    os.umask(0o002)
    user = pwd.getpwuid(os.getuid()).pw_name
    with open(CONF_PATH, encoding="utf-8") as handle:
        conf = json.load(handle)

    entry = conf["usuarios"].get(user)
    if not entry or entry["ambiente"] != args.env:
        fail(4, f"usuario {user} nao publica no ambiente {args.env}")

    presented = sys.stdin.readline().strip()
    try:
        expected = kv_secret(conf["key_vault"], entry["segredo_token"]).strip()
    except Exception as exc:  # noqa: BLE001 - qualquer falha de rede/IMDS recusa
        fail(5, f"nao foi possivel validar o token no Key Vault: {exc}")
    if not presented or not hmac.compare_digest(presented, expected):
        fail(3, "token invalido - acesso negado")

    env_dir = os.path.realpath(os.path.join(BASE_DIR, args.env))
    jcl_path = os.path.realpath(args.file)
    if not jcl_path.startswith(env_dir + os.sep):
        fail(6, f"{args.file} fora de {env_dir}")
    if f".{args.env}." not in args.library or not re.fullmatch(r"[A-Z0-9#@$]{1,8}", args.member):
        fail(7, f"biblioteca/membro invalido: {args.library}({args.member})")

    with open(jcl_path, encoding="utf-8") as handle:
        text = handle.read()
    job_match = re.search(r"^//(\S+)\s+JOB\b", text, re.MULTILINE)
    jobname = job_match.group(1) if job_match else args.member
    steps = re.findall(r"^//(\S+)\s+EXEC\s+(?:PGM=)?([A-Z0-9#@$]+)", text, re.MULTILINE)

    library_dir = os.path.join(env_dir, args.library)
    os.makedirs(library_dir, exist_ok=True)
    shutil.copyfile(jcl_path, os.path.join(library_dir, args.member))

    jobid = next_jobid()
    spool = build_spool(jobid, jobname, user, steps)
    with open(os.path.join(os.path.dirname(jcl_path), f"{jobid}.spool.txt"), "w", encoding="utf-8") as handle:
        handle.write(spool + "\n")

    audit(f"SUBMETIDO {jobid} {jobname} {args.library}({args.member}) <- {jcl_path}")
    print(
        json.dumps(
            {
                "jobid": jobid,
                "jobname": jobname,
                "rc": "0000",
                "member": args.member,
                "library": args.library,
                "spool": spool,
            }
        )
    )


if __name__ == "__main__":
    main()
