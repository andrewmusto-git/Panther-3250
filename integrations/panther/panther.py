#!/usr/bin/env python3
"""
Panther to Veza OAA Integration Script

Collects identity and permission data from Panther SIEM via REST API
(OAuth 2.0 client credentials grant) and pushes to Veza Access Graph.

Entities modelled:
  - Local Users  → Panther users  (GET /v1/users)
  - Local Roles  → Panther roles  (GET /v1/roles)
  - User→Role membership derived from the `role` field on each user object

Authentication:
  OAuth 2.0 client credentials grant — exchanges client_id + client_secret
  for a Bearer token, then uses that token on every Panther API call.

Usage:
  python3 panther.py --dry-run
  python3 panther.py --env-file .env --save-json --log-level DEBUG
"""

import argparse
import json
import logging
import os
import sys
from datetime import datetime
from logging.handlers import TimedRotatingFileHandler
from typing import Any, Dict, List, Optional
from urllib.parse import urlparse

import requests
from requests.auth import HTTPBasicAuth
from dotenv import load_dotenv
from oaaclient.client import OAAClient, OAAClientError
from oaaclient.templates import CustomApplication, OAAPermission

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log = logging.getLogger(__name__)


def _setup_logging(log_level: str = "INFO") -> None:
    """Configure file-only logging with hourly rotation to the logs/ folder."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    log_dir = os.path.join(script_dir, "logs")
    os.makedirs(log_dir, exist_ok=True)

    timestamp = datetime.now().strftime("%d%m%Y-%H%M")
    script_name = os.path.splitext(os.path.basename(__file__))[0]
    log_file = os.path.join(log_dir, f"{script_name}_{timestamp}.log")

    handler = TimedRotatingFileHandler(
        log_file,
        when="h",
        interval=1,
        backupCount=24,
        encoding="utf-8",
    )
    handler.setFormatter(
        logging.Formatter(
            fmt="%(asctime)s %(levelname)-8s %(message)s",
            datefmt="%Y-%m-%dT%H:%M:%S",
        )
    )

    root = logging.getLogger()
    root.setLevel(getattr(logging, log_level.upper(), logging.INFO))
    root.addHandler(handler)


# ---------------------------------------------------------------------------
# Milestone progress reporter
# ---------------------------------------------------------------------------

MILESTONES: List[str] = [
    "OAuth2 token acquisition",
    "Fetching groups from Panther",
    "Fetching users from Panther",
    "Building OAA payload",
    "Pushing to Veza",
]
_MILESTONE_TOTAL = len(MILESTONES)


def milestone(step: int, label: str) -> None:
    """Print a visual progress milestone banner to stdout and write to log."""
    bar_width = 44
    filled = int(bar_width * step / _MILESTONE_TOTAL)
    bar = "\u2588" * filled + "\u2591" * (bar_width - filled)
    pct = int(100 * step / _MILESTONE_TOTAL)
    banner = (
        "\n"
        + "=" * 60 + "\n"
        + f"  [{bar}] {pct:>3}%\n"
        + f"  Step {step}/{_MILESTONE_TOTAL}: {label}\n"
        + "=" * 60
    )
    print(banner)
    log.info("MILESTONE %d/%d — %s", step, _MILESTONE_TOTAL, label)


# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Panther SIEM to Veza OAA Integration",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  python3 panther.py --dry-run\n"
            "  python3 panther.py --env-file .env --save-json --log-level DEBUG\n"
            "  python3 panther.py --panther-base-url https://api.myco.runpanther.net "
            "--dry-run\n"
        ),
    )

    # Veza / general
    parser.add_argument(
        "--env-file", default=".env",
        help="Path to .env file (default: .env)",
    )
    parser.add_argument(
        "--veza-url", default=None,
        help="Veza instance URL (overrides VEZA_URL env var)",
    )
    parser.add_argument(
        "--veza-api-key", default=None,
        help="Veza API key (overrides VEZA_API_KEY env var)",
    )
    parser.add_argument(
        "--provider-name", default="Panther",
        help="OAA provider name shown in Veza UI (default: Panther)",
    )
    parser.add_argument(
        "--datasource-name", default=None,
        help="OAA datasource name shown in Veza UI (default: derived from base URL hostname)",
    )

    # Panther OAuth2 connection settings
    parser.add_argument(
        "--panther-base-url", default=None,
        help="Panther API base URL, e.g. https://api.myco.runpanther.net "
             "(overrides PANTHER_BASE_URL)",
    )
    parser.add_argument(
        "--panther-token-url", default=None,
        help="OAuth2 token endpoint, e.g. https://myco.auth.us-east-1.amazoncognito.com/oauth2/token "
             "(overrides PANTHER_TOKEN_URL)",
    )
    parser.add_argument(
        "--panther-client-id", default=None,
        help="OAuth2 client ID (overrides PANTHER_CLIENT_ID)",
    )
    parser.add_argument(
        "--panther-client-secret", default=None,
        help="OAuth2 client secret (overrides PANTHER_CLIENT_SECRET)",
    )
    parser.add_argument(
        "--panther-scope", default=None,
        help="OAuth2 scope value (overrides PANTHER_SCOPE; leave empty if not required)",
    )
    parser.add_argument(
        "--panther-tenant", default=None,
        help="Tenant ID sent in the 'tenant' request header (overrides PANTHER_TENANT)",
    )
    parser.add_argument(
        "--instance-id", default=None,
        metavar="XXXX",
        help="4-digit Panther instance ID (e.g. 3250). Sets provider name to 'Panther-XXXX', "
             "the install directory to /opt/VEZA/pantherXXXX-veza, and the tenant header "
             "if not overridden via --panther-tenant or PANTHER_TENANT.",
    )

    # Behaviour flags
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Build the OAA payload without pushing to Veza",
    )
    parser.add_argument(
        "--save-json", action="store_true",
        help="Save the OAA payload as a JSON file for inspection",
    )
    parser.add_argument(
        "--log-level", default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
        help="Logging verbosity (default: INFO)",
    )

    return parser.parse_args()


# ---------------------------------------------------------------------------
# Configuration loader
# ---------------------------------------------------------------------------


def load_config(args: argparse.Namespace) -> Dict[str, Any]:
    """Merge CLI args → env vars → .env file (CLI takes highest precedence)."""
    if args.env_file and os.path.exists(args.env_file):
        load_dotenv(args.env_file)

    return {
        "veza_url":              args.veza_url              or os.getenv("VEZA_URL"),
        "veza_api_key":          args.veza_api_key          or os.getenv("VEZA_API_KEY"),
        "panther_base_url":      args.panther_base_url      or os.getenv("PANTHER_BASE_URL"),
        "panther_token_url":     args.panther_token_url     or os.getenv("PANTHER_TOKEN_URL"),
        "panther_client_id":     args.panther_client_id     or os.getenv("PANTHER_CLIENT_ID"),
        "panther_client_secret": args.panther_client_secret or os.getenv("PANTHER_CLIENT_SECRET"),
        "panther_scope":         args.panther_scope         or os.getenv("PANTHER_SCOPE", ""),
        "panther_tenant":        args.panther_tenant        or os.getenv("PANTHER_TENANT", "3250"),
    }


def validate_config(cfg: Dict[str, Any], dry_run: bool) -> None:
    """Exit with a clear error if any required configuration key is absent."""
    required = [
        "panther_base_url",
        "panther_token_url",
        "panther_client_id",
        "panther_client_secret",
    ]
    if not dry_run:
        required += ["veza_url", "veza_api_key"]

    missing = [k for k in required if not cfg.get(k)]
    if missing:
        log.error("Missing required configuration: %s", ", ".join(missing))
        sys.exit(1)


# ---------------------------------------------------------------------------
# OAuth2 token acquisition
# ---------------------------------------------------------------------------


def get_access_token(cfg: Dict[str, Any]) -> str:
    """Obtain an OAuth2 Bearer token using the client credentials grant.

    Sends client_id and client_secret as HTTP Basic Auth credentials with
    grant_type=client_credentials in the POST body.  An optional ``scope``
    parameter is included when PANTHER_SCOPE is non-empty.
    """
    token_url = cfg["panther_token_url"]
    log.debug("Requesting OAuth2 token from %s", token_url)

    post_data: Dict[str, str] = {"grant_type": "client_credentials"}
    scope = cfg.get("panther_scope", "").strip()
    if scope:
        post_data["scope"] = scope

    try:
        resp = requests.post(
            token_url,
            data=post_data,
            auth=HTTPBasicAuth(cfg["panther_client_id"], cfg["panther_client_secret"]),
            timeout=30,
        )
        resp.raise_for_status()
    except requests.HTTPError as exc:
        log.error(
            "OAuth2 token request failed: HTTP %s — %s",
            exc.response.status_code,
            exc.response.text[:500],
        )
        sys.exit(1)
    except requests.RequestException as exc:
        log.error("OAuth2 token request failed: %s", exc)
        sys.exit(1)

    token_data = resp.json()
    access_token = token_data.get("access_token")
    if not access_token:
        log.error("No access_token in OAuth2 response: %s", json.dumps(token_data)[:500])
        sys.exit(1)

    expires_in = token_data.get("expires_in", "unknown")
    token_type = token_data.get("token_type", "Bearer")
    log.info(
        "OAuth2 token obtained (type=%s, expires_in=%s)",
        token_type,
        expires_in,
    )
    return access_token


# ---------------------------------------------------------------------------
# Panther REST API client
# ---------------------------------------------------------------------------


class PantherClient:
    """Minimal Panther REST API client using a Bearer access token."""

    def __init__(self, base_url: str, access_token: str, tenant: str = "3250") -> None:
        # Normalise: strip trailing slash; use the URL exactly as provided
        self.base_url = base_url.rstrip("/")

        self.session = requests.Session()
        self.session.headers.update(
            {
                "Authorization": f"Bearer {access_token}",
                "Accept": "text/plain",
                "Content-Type": "application/json",
                "tenant": tenant,
            }
        )
        log.debug("PantherClient initialised with base_url=%s, tenant=%s", self.base_url, tenant)

    def _get_all_pages(
        self,
        endpoint: str,
        extra_params: Optional[Dict[str, Any]] = None,
    ) -> List[Dict[str, Any]]:
        """Fetch all records from a Panther list endpoint.

        Handles both flat JSON array responses (e.g. /v1/groups) and
        dict responses with a 'results' key and optional cursor pagination.
        """
        url = f"{self.base_url}/{endpoint.lstrip('/')}"
        results: List[Dict[str, Any]] = []
        cursor: Optional[str] = None
        page = 0

        while True:
            params: Dict[str, Any] = {}
            if extra_params:
                params.update(extra_params)
            if cursor:
                params["cursor"] = cursor

            log.debug("GET %s  params=%s", url, params)
            try:
                resp = self.session.get(url, params=params, timeout=30)
                resp.raise_for_status()
            except requests.HTTPError as exc:
                log.error(
                    "Panther API request failed [%s]: HTTP %s — %s",
                    endpoint,
                    exc.response.status_code,
                    exc.response.text[:500],
                )
                sys.exit(1)
            except requests.RequestException as exc:
                log.error("Panther API request failed [%s]: %s", endpoint, exc)
                sys.exit(1)

            data = resp.json()

            # Flat array response (e.g. /v1/groups returns [...])
            if isinstance(data, list):
                results.extend(data)
                log.debug("%s: flat array response — %d items", endpoint, len(data))
                break

            # Wrapped response with 'results' key + optional cursor pagination
            page_results = data.get("results", [])
            results.extend(page_results)
            page += 1
            log.debug(
                "%s page %d: +%d items (running total %d)",
                endpoint,
                page,
                len(page_results),
                len(results),
            )

            cursor = data.get("next")
            if not cursor:
                break

        log.info("Completed fetch for %s: %d total records", endpoint, len(results))
        return results

    def list_roles(self) -> List[Dict[str, Any]]:
        """Return all Panther groups (entitlements) via GET /v1/groups."""
        return self._get_all_pages("v1/groups")

    def list_users(self) -> List[Dict[str, Any]]:
        """Return all Panther users via GET /v1/users."""
        return self._get_all_pages("v1/users")


# ---------------------------------------------------------------------------
# OAA permission classifier
# ---------------------------------------------------------------------------

# Panther permission name keywords → OAA permission classes
_WRITE_KEYWORDS = frozenset(
    ["modify", "manage", "create", "delete", "write", "upload", "run", "send"]
)
_ADMIN_KEYWORDS = frozenset(["admin"])
_READ_KEYWORDS = frozenset(["view", "read", "list", "get"])


def _classify_permission(perm_name: str) -> List[OAAPermission]:
    """Map a Panther permission string to Veza OAA permission types.

    Matching is done against the lower-cased permission name:
      - Contains an admin keyword  → full access set
      - Contains a write keyword   → DataRead + DataWrite
      - Otherwise                  → DataRead (view / read)
    """
    name_lower = perm_name.lower()

    if any(kw in name_lower for kw in _ADMIN_KEYWORDS):
        return [
            OAAPermission.DataRead,
            OAAPermission.DataWrite,
            OAAPermission.MetadataRead,
            OAAPermission.MetadataWrite,
            OAAPermission.NonBusinessContent,
        ]

    if any(kw in name_lower for kw in _WRITE_KEYWORDS):
        return [OAAPermission.DataRead, OAAPermission.DataWrite]

    return [OAAPermission.DataRead]


# ---------------------------------------------------------------------------
# OAA payload builder
# ---------------------------------------------------------------------------


def build_oaa_payload(
    users: List[Dict[str, Any]],
    roles: List[Dict[str, Any]],
    args: argparse.Namespace,
    cfg: Dict[str, Any],
) -> CustomApplication:
    """Assemble the OAA CustomApplication object from Panther users and groups.

    Entity model:
      CustomApplication
        ├─ Local Roles  (one per Panther group, from GET /v1/groups)
        │    └─ Custom Permission: "Member" (DataRead)
        └─ Local Users  (one per Panther user, from GET /v1/users)
             └─ Role membership  (derived from user.groups[*].groupName)
    """
    # Derive a human-readable datasource name from the base URL when not supplied
    datasource_name = args.datasource_name
    if not datasource_name:
        parsed = urlparse(cfg.get("panther_base_url") or "panther")
        datasource_name = parsed.hostname or cfg.get("panther_base_url") or "panther"

    log.info(
        "Building OAA payload — provider=%s, datasource=%s",
        args.provider_name,
        datasource_name,
    )

    app = CustomApplication(
        name=datasource_name,
        application_type=args.provider_name,
        description="Panther SIEM — users and groups collected via OAA REST connector",
    )

    # ------------------------------------------------------------------
    # Step 1: Register a single "Member" permission.
    #         Groups in this API carry no sub-permissions; membership is
    #         the entitlement itself.
    # ------------------------------------------------------------------
    app.add_custom_permission("Member", [OAAPermission.DataRead])
    log.debug("Registered custom permission: Member → DataRead")

    # ------------------------------------------------------------------
    # Step 2: Add groups as local roles
    # ------------------------------------------------------------------
    group_name_set: set = set()

    for group in roles:
        group_name = group.get("groupName", "")
        if not group_name:
            log.warning("Skipping group with missing groupName: %s", group)
            continue

        local_role = app.add_local_role(group_name, unique_id=group_name, permissions=["Member"])
        group_name_set.add(group_name)
        log.debug("Added group as role: %s", group_name)

    log.info("Added %d groups to OAA payload", len(group_name_set))

    # ------------------------------------------------------------------
    # Step 3: Add users and assign group memberships
    # ------------------------------------------------------------------
    unmatched_groups: set = set()

    for user in users:
        user_name = user.get("userName", user.get("email", ""))
        email = user.get("email", "")
        full_name = user.get("fullName", "").strip() or email
        is_active = bool(user.get("isActive", True))

        local_user = app.add_local_user(full_name, unique_id=user_name)
        local_user.is_active = is_active

        for g in user.get("groups", []):
            gname = g.get("groupName", "")
            if not gname:
                continue
            if gname in group_name_set:
                local_user.add_role(gname, apply_to_application=True)
                log.debug("User %s → group %s", user_name, gname)
            else:
                unmatched_groups.add(gname)
                log.warning(
                    "User %s references unknown group '%s' — membership skipped",
                    user_name,
                    gname,
                )

    if unmatched_groups:
        log.warning(
            "The following group references were not resolved: %s",
            ", ".join(sorted(unmatched_groups)),
        )

    log.info(
        "Added %d users to OAA payload (active=%d, inactive=%d)",
        len(users),
        sum(1 for u in users if u.get("isActive", True)),
        sum(1 for u in users if not u.get("isActive", True)),
    )

    return app


def _derive_datasource_name(args: argparse.Namespace, cfg: Dict[str, Any]) -> str:
    """Return the datasource name to use for Veza push / output messages."""
    if args.datasource_name:
        return args.datasource_name
    parsed = urlparse(cfg.get("panther_base_url") or "panther")
    return parsed.hostname or cfg.get("panther_base_url") or "panther"


# ---------------------------------------------------------------------------
# Veza push
# ---------------------------------------------------------------------------


def push_to_veza(
    veza_url: str,
    veza_api_key: str,
    provider_name: str,
    datasource_name: str,
    app: CustomApplication,
    dry_run: bool = False,
    save_json: bool = False,
) -> Optional[str]:
    """Optionally persist the JSON payload, then push to Veza (unless dry-run).

    Returns the path to the saved JSON file if save_json=True, else None.
    """
    json_path: Optional[str] = None

    if save_json:
        json_path = os.path.join(
            os.path.dirname(os.path.abspath(__file__)),
            f"panther_payload_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json",
        )
        try:
            with open(json_path, "w", encoding="utf-8") as fh:
                json.dump(app.get_payload(), fh, indent=2, default=str)
            log.info("OAA payload saved to %s", json_path)
            print(f"\n  Payload saved → {json_path}")
        except OSError as exc:
            log.warning("Could not save JSON payload: %s", exc)
            json_path = None

    if dry_run:
        log.info("[DRY RUN] Payload assembled successfully — Veza push skipped")
        print("\n  [DRY RUN] Veza push skipped.")
        return json_path

    veza_con = OAAClient(url=veza_url, token=veza_api_key)
    try:
        response = veza_con.push_application(
            provider_name=provider_name,
            data_source_name=datasource_name,
            application_object=app,
            create_provider=True,
        )
        if response and response.get("warnings"):
            for w in response["warnings"]:
                log.warning("Veza push warning: %s", w)
        log.info(
            "Successfully pushed to Veza — provider=%s, datasource=%s",
            provider_name,
            datasource_name,
        )
    except OAAClientError as exc:
        log.error(
            "Veza push failed: %s — %s (HTTP %s)",
            exc.error,
            exc.message,
            exc.status_code,
        )
        if hasattr(exc, "details"):
            for detail in exc.details:
                log.error("  Veza detail: %s", detail)
        sys.exit(1)

    return json_path


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() -> None:
    args = parse_args()
    _setup_logging(args.log_level)

    # ------------------------------------------------------------------
    # Instance ID — prompt if not supplied on the CLI
    # ------------------------------------------------------------------
    instance_id = args.instance_id
    if not instance_id:
        print("\n" + "=" * 60)
        print("  Panther \u2192 Veza OAA Integration \u2014 Instance Setup")
        print("=" * 60)
        while True:
            instance_id = input(
                "\n  Enter the 4-digit Panther instance ID\n"
                "  (sets provider name to 'Panther-XXXX', e.g. 3250): "
            ).strip()
            if instance_id.isdigit() and len(instance_id) == 4:
                break
            print("  Invalid \u2014 please enter exactly 4 digits (e.g. 3250).")

    DEFAULT_INSTALL_DIR = f"/opt/VEZA/panther{instance_id}-veza"
    # Override provider_name unless --provider-name was explicitly set
    if args.provider_name == "Panther":
        args.provider_name = f"Panther-{instance_id}"

    # Startup banner (print() intentional here — visible even when log level is high)
    print("\n" + "=" * 60)
    print("  Panther \u2192 Veza OAA Integration")
    print(f"  Started     : {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"  Instance    : {instance_id}")
    print(f"  Provider    : {args.provider_name}")
    print(f"  Install dir : {DEFAULT_INSTALL_DIR}")
    print(f"  Mode        : {'DRY RUN (no Veza push)' if args.dry_run else 'LIVE PUSH'}")
    print("=" * 60)

    cfg = load_config(args)
    # Use instance_id as the tenant unless explicitly overridden via CLI or env var
    if not args.panther_tenant and not os.getenv("PANTHER_TENANT"):
        cfg["panther_tenant"] = instance_id
    validate_config(cfg, dry_run=args.dry_run)

    # -------------------------------------------------------------------
    # Milestone 1 — OAuth2 token acquisition
    # -------------------------------------------------------------------
    milestone(1, MILESTONES[0])
    access_token = get_access_token(cfg)
    print(f"  Token acquired from {cfg['panther_token_url']}")
    log.info("Access token acquired successfully")

    # -------------------------------------------------------------------
    # Milestone 2 — Fetch roles
    # -------------------------------------------------------------------
    milestone(2, MILESTONES[1])
    client = PantherClient(cfg["panther_base_url"], access_token, tenant=cfg["panther_tenant"])
    roles = client.list_roles()
    print(f"  Groups fetched  : {len(roles)}")
    log.info("Fetched %d group(s) from Panther", len(roles))

    # -------------------------------------------------------------------
    # Milestone 3 — Fetch users
    # -------------------------------------------------------------------
    milestone(3, MILESTONES[2])
    users = client.list_users()
    active_count = sum(1 for u in users if u.get("isActive", True))
    inactive_count = len(users) - active_count
    print(f"  Users fetched   : {len(users)} total ({active_count} active, {inactive_count} inactive)")
    log.info("Fetched %d user(s) from Panther", len(users))

    # -------------------------------------------------------------------
    # Milestone 4 — Build OAA payload
    # -------------------------------------------------------------------
    milestone(4, MILESTONES[3])
    app = build_oaa_payload(users, roles, args, cfg)
    datasource_name = _derive_datasource_name(args, cfg)
    print(f"  Payload built   : {len(users)} users, {len(roles)} groups")

    # -------------------------------------------------------------------
    # Milestone 5 — Push to Veza
    # -------------------------------------------------------------------
    milestone(5, MILESTONES[4])
    json_path = push_to_veza(
        veza_url=cfg["veza_url"],
        veza_api_key=cfg["veza_api_key"],
        provider_name=args.provider_name,
        datasource_name=datasource_name,
        app=app,
        dry_run=args.dry_run,
        save_json=args.save_json,
    )

    # -------------------------------------------------------------------
    # Final summary
    # -------------------------------------------------------------------
    print("\n" + "=" * 60)
    print("  Run complete")
    print(f"  Users         : {len(users)}")
    print(f"  Groups        : {len(roles)}")
    print(f"  Provider      : {args.provider_name}")
    print(f"  Datasource    : {datasource_name}")
    print(f"  Mode          : {'DRY RUN' if args.dry_run else 'PUSHED TO VEZA'}")
    if json_path:
        print(f"  Payload JSON  : {json_path}")
    print("=" * 60 + "\n")

    log.info(
        "Run complete — users=%d, groups=%d, mode=%s",
        len(users),
        len(roles),
        "dry-run" if args.dry_run else "live",
    )


if __name__ == "__main__":
    main()
