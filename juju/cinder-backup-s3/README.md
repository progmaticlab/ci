Overview
--------

Usage
-----

Once ready, deploy and relate as follows:

    juju deploy cinder
    juju deploy cinder-backup-s3
    juju add-relation cinder-backup-s3 cinder
