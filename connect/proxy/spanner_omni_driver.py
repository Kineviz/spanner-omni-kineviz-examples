"""A Spanner Omni driver for graphxr-database-proxy.

Kineviz reaches Spanner through `graphxr-database-proxy`, whose Spanner driver
builds a client for *managed* Spanner: it authenticates with OAuth, a service
account, or ADC, and it talks to spanner.googleapis.com. A Spanner Omni
deployment has none of those. It is an endpoint on a host you control, with no
credentials in the preview build, and its project and instance are both the
literal string `default`.

The gap is small and it is entirely in how the client is constructed, so this
subclasses the shipped driver and overrides exactly that. Everything else —
schema introspection, GQL execution, the shape of the JSON handed back to the
canvas — is inherited unchanged, which is the point: query behaviour stays
whatever upstream says it is.

Upstream this is written against:
    https://github.com/Kineviz/graphxr-database-proxy
    commit cfdcadf1ea0e542259069d031a95648e214e0605 (2026-05-22)

A subclass rather than a patch because a patch against a moving file rots on the
first upstream edit; an override of one method usually does not. If upstream
renames `connect()` or stops storing `self.client`/`self.instance`/`self.database`,
this needs revisiting — that is the contract it depends on, and it is a small one.

INSTALL

    1. Copy this file into the proxy checkout:
         cp spanner_omni_driver.py \
            graphxr-database-proxy/src/graphxr_database_proxy/drivers/

    2. Register it, replacing the managed-Spanner driver. In
       `src/graphxr_database_proxy/drivers/factory.py`, add the import and swap
       the mapping entry:

         from .spanner_omni_driver import SpannerOmniDriver
         ...
         _drivers: Dict[DatabaseType, Type[BaseDatabaseDriver]] = {
             DatabaseType.SPANNER: SpannerOmniDriver,   # was SpannerDriver
             DatabaseType.ROCKETGRAPH: RocketGraphDriver,
         }

       Swapping rather than adding keeps it to one line. If you need the same
       proxy to serve both managed Spanner and Omni, register Omni under its own
       DatabaseType instead and leave `DatabaseType.SPANNER` alone.

    3. Restart the proxy, create a project with database type
       "Google Cloud Spanner", and fill in:

         Host        localhost           (or wherever the deployment runs)
         Port        15000
         Project ID  default             ← not yours; fixed by Spanner Omni
         Instance ID default             ← same
         Database ID your database
         Graph       your property graph

       Authentication type is ignored — the preview build of Spanner Omni has
       no auth. Leave whatever the form insists on.

SECURITY

Spanner Omni's preview build supports no TLS, so this connection is plain text
and unauthenticated. Anyone who can reach the endpoint can read and write every
database on it. Keep the deployment on loopback or inside a network you control,
and do not put one on a shared host. That is a property of the preview build,
not of this file.
"""

from __future__ import annotations

from typing import Optional

from google.cloud import spanner
from google.cloud.spanner_v1 import Client

from .spanner import SpannerDriver

# Fixed by Spanner Omni. The Java documentation spells it out as
# DatabaseId.of("default", "default", DATABASE_ID); every client library needs
# the same two values.
OMNI_PROJECT = "default"
OMNI_INSTANCE = "default"

DEFAULT_HOST = "localhost"
DEFAULT_PORT = 15000

# The google-cloud-spanner release that first supported Omni at all. An older
# client fails with an authentication error rather than a version error, which
# sends people looking in exactly the wrong place.
MIN_CLIENT = "3.65.0"


class SpannerOmniDriver(SpannerDriver):
    """SpannerDriver, pointed at a Spanner Omni deployment instead of Google's."""

    def _endpoint(self) -> str:
        host = self.config.host or DEFAULT_HOST
        port = self.config.port or DEFAULT_PORT
        return f"{host}:{port}"

    async def _get_omni_client(self) -> Client:
        """Build the client, preferring the current API over the deprecated one.

        Google's Spanner Omni documentation still shows `experimental_host=`.
        The client has moved on: as of 3.69.1 that argument emits a
        DeprecationWarning pointing at `client_options={"api_endpoint": ...}`
        together with `instance_type="omni"`. Both work today; the new form is
        what will survive, so try it first and fall back for 3.65–3.68.

        `use_plain_text=True` is not optional on either path. Without it the
        client insists on TLS and raises "TLS/mTLS connection requires
        ca_certificate to be set for Spanner Omni" — and the preview build of
        Spanner Omni does not serve TLS at all.
        """
        endpoint = self._endpoint()
        try:
            return spanner.Client(
                project=OMNI_PROJECT,
                client_options={"api_endpoint": endpoint},
                instance_type="omni",
                use_plain_text=True,
            )
        except TypeError:
            pass  # older client: no instance_type. Fall through.

        try:
            return spanner.Client(
                project=OMNI_PROJECT,
                experimental_host=endpoint,
                use_plain_text=True,
            )
        except TypeError as e:
            raise ConnectionError(
                "This google-cloud-spanner is too old for Spanner Omni "
                f"(need >={MIN_CLIENT}). "
                "Upgrade the proxy's environment: uv pip install -U 'google-cloud-spanner>=3.65.0'"
            ) from e

    async def connect(self) -> None:
        """Open the connection.

        Deliberately ignores `auth_type`. The preview build of Spanner Omni has
        no authentication at all, so honouring the form's auth selection would
        mean failing on a credential the deployment would never have checked.
        """
        endpoint = self._endpoint()
        try:
            print(f"[INFO] Connecting to Spanner Omni at {endpoint} (plain text, no auth)")
            self.client = await self._get_omni_client()

            if not self.config.database_id:
                raise ValueError("database_id is required")

            # Project and instance are not read from the form on purpose. If
            # someone types their GCP project into that field, honouring it
            # produces a NotFound against a deployment that only has `default`.
            self.instance = self.client.instance(OMNI_INSTANCE)
            self.database = self.instance.database(self.config.database_id)

            print(f"[INFO] Project: {OMNI_PROJECT} (fixed)")
            print(f"[INFO] Instance: {OMNI_INSTANCE} (fixed)")
            print(f"[INFO] Database: {self.config.database_id}")
            print("[OK] Spanner Omni connection established")

        except Exception as e:
            print(f"[ERROR] Failed to connect to Spanner Omni: {e}")
            raise ConnectionError(
                f"Failed to connect to Spanner Omni at {endpoint}: {e}"
            ) from e

    async def disconnect(self) -> Optional[None]:
        return await super().disconnect()
