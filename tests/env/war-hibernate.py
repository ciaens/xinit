"""Switch the hibernate.cfg.xml of the XWiki WAR from HSQLDB to another database.

Usage: war-hibernate.py <hibernate.cfg.xml> <pgsql|mariadb>

The WAR ships the HSQLDB block active and every other database as a commented-out block whose
comment starts with "<!-- <Name> configuration." and ends after its last <mapping>. The default
block is removed (it holds nested comments, so it cannot be commented out), and the comment around
the chosen block is opened after its notes and closed where it used to end.
"""
import re
import sys
import xml.dom.minidom

path, db = sys.argv[1], sys.argv[2]
name = {"pgsql": "PostgreSQL", "mariadb": "MariaDB"}[db]
s = open(path, encoding="utf-8").read()

# 1. Remove the active default (HSQLDB) block: from its first property to its last mapping.
default = s.index("<!-- Configuration for the default database.")
start = s.index('<property name="hibernate.connection.url">', default)
end = s.index('<mapping resource="mailsender.hbm.xml"/>', start) + len('<mapping resource="mailsender.hbm.xml"/>')
s = s[:start] + s[end:]

# 2. Uncomment the chosen block.
block = s.index(f"<!-- {name} configuration.")
first = s.index("<property", block)
close = s.index("-->", first)
s = s[:first] + "-->\n    " + s[first:close] + s[close + 3:]

xml.dom.minidom.parseString(s.encode("utf-8"))  # fails loudly if the result is not well-formed
urls = re.findall(r'<property name="hibernate.connection.url">([^<]*)<', re.sub(r"<!--.*?-->", "", s, flags=re.S))
if len(urls) != 1 or not urls[0].startswith(f"jdbc:{ {'pgsql': 'postgresql', 'mariadb': 'mariadb'}[db] }:"):
    sys.exit(f"unexpected active connection URLs after the switch: {urls}")
open(path, "w", encoding="utf-8").write(s)
print(f"{path}: {name} block active ({urls[0]})")
