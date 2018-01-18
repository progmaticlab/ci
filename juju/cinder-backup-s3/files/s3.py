"""Implementation of a backup service using S3 Storage
"""

import hashlib
import socket

from oslo_config import cfg
from oslo_utils import timeutils
from oslo_log import log as logging
import botocore.session
import six

from cinder.backup import chunkeddriver
from cinder import exception
from cinder import interface

from keystoneauth1 import identity
from keystoneauth1 import loading as ka_loading
from keystoneclient.v3 import client
from keystoneclient.v3.credentials import CredentialManager
import json


LOG = logging.getLogger(__name__)

s3backup_service_opts = [
    cfg.StrOpt('backup_s3_url',
               help='The URL of the S3 endpoint'),
    cfg.IntOpt('backup_s3_object_size',
               default=52428800,
               help='The size in bytes of S3 backup objects'),
    cfg.IntOpt('backup_s3_block_size',
               default=32768,
               help='The size in bytes that changes are tracked '
                    'for incremental backups. backup_s3_object_size '
                    'has to be multiple of backup_s3_block_size.'),
    cfg.StrOpt('backup_s3_container',
               default='volumebackups',
               help='The default S3 container to use'),
    cfg.BoolOpt('backup_s3_enable_progress_timer',
                default=True,
                help='Enable or Disable the timer to send the periodic '
                     'progress notifications to Ceilometer when backing '
                     'up the volume to the S3 backend storage. The '
                     'default value is True to enable the timer.'),
]

CONF = cfg.CONF
CONF.register_opts(s3backup_service_opts)
CONF.import_opt('auth_uri', 'keystonemiddleware.auth_token.__init__',
                'keystone_authtoken')

def s3_logger(func):
    def func_wrapper(self, *args, **kwargs):
        LOG.debug('s3_logger: ' + func.__name__)
        return func(self, *args, **kwargs)
    return func_wrapper


@interface.backupdriver
class S3BackupDriver(chunkeddriver.ChunkedBackupDriver):
    @s3_logger
    def __init__(self, context, db=None):
        chunk_size_bytes = CONF.backup_s3_object_size
        sha_block_size_bytes = CONF.backup_s3_block_size
        backup_default_container = CONF.backup_s3_container + '-' + context.user_id
        enable_progress_timer = CONF.backup_s3_enable_progress_timer
        endpoint_url = CONF.backup_s3_url
        super(S3BackupDriver, self).__init__(context, chunk_size_bytes,
                                                sha_block_size_bytes,
                                                backup_default_container,
                                                enable_progress_timer,
                                                db)
        aws_key, aws_secret = self._get_credentials(context)
        #LOG.info('kredy: ' + aws_key + ', ' + aws_secret)
        session = botocore.session.get_session()
        self.conn = session.create_client('s3', 
                   endpoint_url=endpoint_url,
                   aws_access_key_id=aws_key,
                   aws_secret_access_key=aws_secret)

    @s3_logger
    def _get_credentials(self, context):
        keystone_client = self._keystone_client(context)
        manager = CredentialManager(keystone_client)
        cred_list = manager.list(user_id = context.user_id)
        for cred in cred_list:
            blob = json.loads(cred.blob)
            if "access" in blob and "secret" in blob and "date" in blob:
                return blob["access"], blob["secret"]
        return "", ""

    @s3_logger
    def _keystone_client(self, context, version=(3, 0)):
        auth_plugin = identity.Token(
            auth_url=CONF.keystone_authtoken.auth_uri,
            token=context.auth_token,
            project_id=context.project_id)

        client_session = ka_loading.session.Session().load_from_options(
           auth=auth_plugin,
            insecure=CONF.keystone_authtoken.insecure,
            cacert=CONF.keystone_authtoken.cafile,
            key=CONF.keystone_authtoken.keyfile,
            cert=CONF.keystone_authtoken.certfile)
        return client.Client(auth_url=CONF.keystone_authtoken.auth_uri,
                         session=client_session, version=version)

    @s3_logger
    def put_container(self, bucket):
        self.conn.create_bucket(Bucket=bucket, ACL='private')

    @s3_logger
    def get_container_entries(self, container, prefix):
        obj_list = self.conn.list_objects(Bucket=container, Prefix=prefix)
        if 'Contents' in obj_list:
            return [obj['Key'] for obj in obj_list['Contents']]
        return []

    @s3_logger
    def get_object_writer(self, container, object_name, extra_metadata=None):
        return self.S3ObjectWriter(container, object_name, self.conn)

    @s3_logger
    def get_object_reader(self, container, object_name, extra_metadata=None):
        return self.S3ObjectReader(container, object_name, self.conn)

    @s3_logger
    def delete_object(self, container, object_name):
        self.conn.delete_object(Bucket=container, Key=object_name)

    @s3_logger
    def _generate_object_name_prefix(self, backup):
        """Generates a S3 backup object name prefix."""
        az = 'az_%s' % self.az
        backup_name = '%s_backup_%s' % (az, backup['id'])
        volume = 'volume_%s' % (backup['volume_id'])
        timestamp = timeutils.utcnow().strftime("%Y%m%d%H%M%S")
        prefix = volume + '/' + timestamp + '/' + backup_name
        LOG.debug('generate_object_name_prefix: %s', prefix)
        return prefix

    @s3_logger
    def update_container_name(self, backup, container):
        """Use the container name as provided - don't update."""
        return container

    @s3_logger
    def get_extra_metadata(self, backup, volume):
        """S3 driver does not use any extra metadata."""
        return None

    class S3ObjectWriter(object):
        def __init__(self, container, object_name, conn):
            self.container = container
            self.object_name = object_name
            self.conn = conn
            self.data = bytearray()

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc_value, traceback):
            self.close()

        @s3_logger
        def write(self, data):
            self.data += data

        @s3_logger
        def close(self):
            reader = six.BytesIO(self.data)
            resp = self.conn.put_object(Bucket=self.container, 
                        Key=self.object_name,
                        ContentLength=len(self.data),
                        Body=reader)

            md5 = hashlib.md5(self.data).hexdigest()
            etag = resp['ETag'].strip('"')
            if etag != md5:
                err = ('MD5 of object: %(object_name)s before: '
                    '%(md5)s and after: %(etag)s is not same.') % {
                    'object_name': self.object_name,
                    'md5': md5, 'etag': etag, }
                raise exception.InvalidBackup(reason=err)
            else:
                LOG.debug('MD5 before: %(md5)s and after: %(etag)s '
                          'writing object: %(object_name)s in GCS.',
                          {'etag': etag, 'md5': md5,
                           'object_name': self.object_name, })
            return md5

    class S3ObjectReader(object):
        def __init__(self, container, object_name, conn):
            self.container = container
            self.object_name = object_name
            self.conn = conn

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc_value, traceback):
            pass

        @s3_logger
        def read(self):
            resp = self.conn.get_object(Bucket=self.container, Key=self.object_name)
            body = resp['Body']
            try:
                return body.read()
            finally:
                body.close()


def get_backup_driver(context):
    return S3BackupDriver(context)
