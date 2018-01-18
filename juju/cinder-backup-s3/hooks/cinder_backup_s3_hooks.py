#!/usr/bin/env python

import json
import shutil
import sys

from charmhelpers.fetch import apt_install, apt_update
from charmhelpers.core.hookenv import (
    Hooks,
    UnregisteredHookError,
    config,
    log,
    related_units,
    relation_ids,
    relation_set,
)


hooks = Hooks()
config = config()


def _notify_neutron():
    for rid in relation_ids("neutron-api"):
        if related_units(rid):
            neutron_api_joined(rid)


@hooks.hook('install')
def install():
    apt_install(['cinder-backup', 'python-botocore'], fatal=True)
    shutil.copy("files/s3.py", "/usr/lib/python2.7/dist-packages/cinder/backup/drivers/")


@hooks.hook('upgrade-charm')
@hooks.hook('config-changed')
def config_changed():
    if config.changed('s3-url'):
        _notify_neutron()


@hooks.hook('backup-backend-relation-joined')
def backup_backend_joined(rel_id=None):
    settings = {
        "cinder": {
            "/etc/cinder/cinder.conf": {
                "sections": {
                    'DEFAULT': [
                        ('backup_driver', 'cinder.backup.drivers.s3'),
                        ('backup_s3_url', config.get('s3-url')),
                    ]
                }
            }
        }
    }
    relation_set(relation_id=rel_id, subordinate_configuration=json.dumps(settings))
    relation_set(relation_id=rel_id, stateless=True)


def main():
    try:
        hooks.execute(sys.argv)
    except UnregisteredHookError as e:
        log("Unknown hook {} - skipping.".format(e))


if __name__ == "__main__":
    main()
