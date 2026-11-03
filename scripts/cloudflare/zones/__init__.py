"""Registry of the zones these scripts manage. Each module declares ZONE_NAME, APEX, ORIGIN,
desired_records() and its proxied host lists. To add a domain, add a module and one line here."""

from zones import codevertexafrica, hadiafrica

ZONES = {
    codevertexafrica.ZONE_NAME: codevertexafrica,
    hadiafrica.ZONE_NAME: hadiafrica,
}
