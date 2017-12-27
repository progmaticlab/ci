#!/bin/bash -ex

neutron_bgp_speaker_ip=$1

echo "$neutron_bgp_speaker_ip" > bgp_peer
