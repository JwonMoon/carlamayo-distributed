"""Deployment scripts: syntax, hosts.env loading, and the example file's keys."""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = sorted((ROOT / "deploy" / "scripts").glob("*.sh")) + [ROOT / "tools" / "fetch_server_profile.sh"]

pytestmark = pytest.mark.skipif(shutil.which("bash") is None, reason="bash required")


@pytest.mark.parametrize("script", SCRIPTS, ids=lambda p: p.name)
def test_script_syntax(script):
    subprocess.run(["bash", "-n", str(script)], check=True)


def test_hosts_env_example_has_required_keys():
    text = (ROOT / "deploy" / "hosts.env.example").read_text()
    for key in ("SIM_HOST_IP", "INFERENCE_HOST_IP", "INFERENCE_PORT", "INFERENCE_SSH_USER", "REMOTE_REPO"):
        assert f"\n{key}=" in text, key


def _load(tmp_path, hosts_env: str | None, env: dict | None = None):
    deploy = tmp_path / "deploy"
    (deploy / "scripts").mkdir(parents=True)
    shutil.copy(ROOT / "deploy" / "scripts" / "hosts-env.sh", deploy / "scripts" / "hosts-env.sh")
    if hosts_env is not None:
        (deploy / "hosts.env").write_text(hosts_env)
    cmd = 'source deploy/scripts/hosts-env.sh; echo "$INFERENCE_TARGET|$INFERENCE_HOST|$REMOTE_REPO|$SIM_HOST_IP"'
    full_env = {k: v for k, v in os.environ.items() if not k.startswith(("INFERENCE_", "SIM_HOST", "REMOTE_REPO"))}
    full_env.update(env or {})
    out = subprocess.run(["bash", "-c", cmd], cwd=tmp_path, env=full_env, capture_output=True, text=True, check=True)
    return out.stdout.strip().split("|")


def test_hosts_env_builds_target_and_ssh_host(tmp_path):
    target, ssh_host, repo, sim = _load(tmp_path, "SIM_HOST_IP=10.0.0.1 # sim\nINFERENCE_HOST_IP = 10.0.0.2\nINFERENCE_PORT=6000\nINFERENCE_SSH_USER=ec2-user\nREMOTE_REPO=/opt/carlamayo\n")
    assert (target, ssh_host, repo, sim) == ("10.0.0.2:6000", "ec2-user@10.0.0.2", "/opt/carlamayo", "10.0.0.1")


def test_environment_overrides_hosts_env(tmp_path):
    target, ssh_host, _, _ = _load(tmp_path, "INFERENCE_HOST_IP=10.0.0.2\n", env={"INFERENCE_HOST_IP": "10.9.9.9"})
    assert target == "10.9.9.9:50051" and ssh_host == "ubuntu@10.9.9.9"


def test_missing_hosts_env_leaves_target_empty(tmp_path):
    target, ssh_host, repo, _ = _load(tmp_path, None)
    assert target == "" and ssh_host == "" and repo == "~/carlamayo"


def test_verify_scripts_fail_cleanly_without_setup(tmp_path):
    """Running the verify scripts on a bare machine must report FAIL lines, not crash."""
    for name in ("verify-sim-host.sh", "verify-inference-host.sh"):
        out = subprocess.run(["bash", str(ROOT / "deploy" / "scripts" / name)], cwd=ROOT, capture_output=True, text=True,
                             env={**os.environ, "PY": "/nonexistent/python"}, check=False)
        assert out.returncode == 1
        assert "FAIL" in out.stdout and "Traceback" not in out.stdout + out.stderr
