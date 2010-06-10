#!/bin/bash
#

# Copyright (C) 2010 Google Inc.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
# 02110-1301, USA.

set -e
set -o pipefail

export PYTHON=${PYTHON:=python}

impexpd="$PYTHON daemons/import-export -d"

err() {
  echo "$@"
  echo 'Aborting'
  show_output
  exit 1
}

show_output() {
  if [[ -s "$gencert_output" ]]; then
    echo
    echo 'Generating certificates:'
    cat $gencert_output
  fi
  if [[ -s "$dst_output" ]]; then
    echo
    echo 'Import output:'
    cat $dst_output
  fi
  if [[ -s "$src_output" ]]; then
    echo
    echo 'Export output:'
    cat $src_output
  fi
}

checkpids() {
  local result=0

  # Unlike combining the "wait" commands using || or &&, this ensures we
  # actually wait for all PIDs.
  for pid in "$@"; do
    if ! wait $pid; then
      result=1
    fi
  done

  return $result
}

get_testpath() {
  echo "${TOP_SRCDIR:-.}/test"
}

get_testfile() {
  echo "$(get_testpath)/data/$1"
}

upto() {
  echo "$(date '+%F %T'):" "$@" '...'
}

statusdir=$(mktemp -d)
trap "rm -rf $statusdir" EXIT

gencert_output=$statusdir/gencert.output

src_statusfile=$statusdir/src.status
src_output=$statusdir/src.output
src_x509=$statusdir/src.pem

dst_statusfile=$statusdir/dst.status
dst_output=$statusdir/dst.output
dst_x509=$statusdir/dst.pem

other_x509=$statusdir/other.pem

testdata=$statusdir/data1
largetestdata=$statusdir/data2

upto 'Command line parameter tests'

$impexpd >/dev/null 2>&1 &&
  err "daemon-util succeeded without parameters"

$impexpd foo bar baz moo boo >/dev/null 2>&1 &&
  err "daemon-util succeeded with wrong parameters"

$impexpd $src_statusfile >/dev/null 2>&1 &&
  err "daemon-util succeeded with insufficient parameters"

$impexpd $src_statusfile invalidmode >/dev/null 2>&1 &&
  err "daemon-util succeeded with invalid mode"

$impexpd $src_statusfile import --compression=rot13 >/dev/null 2>&1 &&
  err "daemon-util succeeded with invalid compression"

upto 'Generate test data'
cat $(get_testfile proc_drbd8.txt) $(get_testfile cert1.pem) > $testdata

# Generate about 7.5 MB of test data
{ tmp="$(<$testdata)"
  for (( i=0; i < 100; ++i )); do
    echo "$tmp $tmp $tmp $tmp $tmp $tmp"
  done
  dd if=/dev/zero bs=1024 count=4096 2>/dev/null
  for (( i=0; i < 100; ++i )); do
    echo "$tmp $tmp $tmp $tmp $tmp $tmp"
  done
} > $largetestdata

impexpd_helper() {
  $PYTHON $(get_testpath)/import-export_unittest-helper "$@"
}

start_test() {
  upto "$@"

  rm -f $src_statusfile $dst_output $dst_statusfile $dst_output
  rm -f $gencert_output

  imppid=
  exppid=

  cmd_prefix=
  cmd_suffix=
  connect_timeout=30
  connect_retries=1
  compress=gzip
}

wait_import_ready() {
  # Wait for listening port
  impexpd_helper $dst_statusfile listen-port
}

do_export() {
  local port=$1

  $impexpd $src_statusfile export --bind=127.0.0.1 \
    --host=127.0.0.1 --port=$port \
    --key=$src_x509 --cert=$src_x509 --ca=$dst_x509 \
    --cmd-prefix="$cmd_prefix" --cmd-suffix="$cmd_suffix" \
    --connect-timeout=$connect_timeout \
    --connect-retries=$connect_retries \
    --compress=$compress
}

do_import() {
  $impexpd $dst_statusfile import --bind=127.0.0.1 \
    --host=127.0.0.1 \
    --key=$dst_x509 --cert=$dst_x509 --ca=$src_x509 \
    --cmd-prefix="$cmd_prefix" --cmd-suffix="$cmd_suffix" \
    --connect-timeout=$connect_timeout \
    --connect-retries=$connect_retries \
    --compress=$compress
}

upto 'Generate X509 certificates and keys'
impexpd_helper $src_x509 gencert 2>$gencert_output & srccertpid=$!
impexpd_helper $dst_x509 gencert 2>$gencert_output & dstcertpid=$!
impexpd_helper $other_x509 gencert 2>$gencert_output & othercertpid=$!
checkpids $srccertpid $dstcertpid $othercertpid || \
  err 'Failed to generate certificates'

start_test 'Normal case'
do_import > $statusdir/recv1 2>$dst_output & imppid=$!
if port=$(wait_import_ready 2>$src_output); then
  do_export $port < $testdata >>$src_output 2>&1 & exppid=$!
fi
checkpids $exppid $imppid || err 'An error occurred'
cmp $testdata $statusdir/recv1 || err 'Received data does not match input'

start_test 'Export using wrong CA'
# Setting lower timeout to not wait for too long
connect_timeout=1 do_import &>$dst_output & imppid=$!
if port=$(wait_import_ready 2>$src_output); then
  : | dst_x509=$other_x509 do_export $port >>$src_output 2>&1 & exppid=$!
fi
checkpids $exppid $imppid && err 'Export did not fail when using wrong CA'

start_test 'Import using wrong CA'
# Setting lower timeout to not wait for too long
src_x509=$other_x509 connect_timeout=1 do_import &>$dst_output & imppid=$!
if port=$(wait_import_ready 2>$src_output); then
  : | do_export $port >>$src_output 2>&1 & exppid=$!
fi
checkpids $exppid $imppid && err 'Import did not fail when using wrong CA'

start_test 'Suffix command on import'
cmd_suffix="| cksum > $statusdir/recv2" do_import &>$dst_output & imppid=$!
if port=$(wait_import_ready 2>$src_output); then
  do_export $port < $testdata >>$src_output 2>&1 & exppid=$!
fi
checkpids $exppid $imppid || err 'Testing additional commands failed'
cmp $statusdir/recv2 <(cksum < $testdata) || \
  err 'Checksum of received data does not match'

start_test 'Prefix command on export'
do_import > $statusdir/recv3 2>$dst_output & imppid=$!
if port=$(wait_import_ready 2>$src_output); then
  cmd_prefix='cksum |' do_export $port <$testdata >>$src_output 2>&1 & exppid=$!
fi
checkpids $exppid $imppid || err 'Testing additional commands failed'
cmp $statusdir/recv3 <(cksum < $testdata) || \
  err 'Received checksum does not match'

start_test 'Failing prefix command on export'
: | cmd_prefix='exit 1;' do_export 0 &>$src_output & exppid=$!
checkpids $exppid && err 'Prefix command on export did not fail when it should'

start_test 'Failing suffix command on export'
do_import >&$dst_output & imppid=$!
if port=$(wait_import_ready 2>$src_output); then
  : | cmd_suffix='| exit 1' do_export $port >>$src_output 2>&1 & exppid=$!
fi
checkpids $imppid $exppid && \
  err 'Suffix command on export did not fail when it should'

start_test 'Failing prefix command on import'
cmd_prefix='exit 1;' do_import &>$dst_output & imppid=$!
checkpids $imppid && err 'Prefix command on import did not fail when it should'

start_test 'Failing suffix command on import'
cmd_suffix='| exit 1' do_import &>$dst_output & imppid=$!
if port=$(wait_import_ready 2>$src_output); then
  : | do_export $port >>$src_output 2>&1 & exppid=$!
fi
checkpids $imppid $exppid && \
  err 'Suffix command on import did not fail when it should'

start_test 'Listen timeout A'
# Setting lower timeout to not wait too long (there won't be anything trying to
# connect)
connect_timeout=1 do_import &>$dst_output & imppid=$!
checkpids $imppid && \
  err 'Listening with timeout did not fail when it should'

start_test 'Listen timeout B'
do_import &>$dst_output & imppid=$!
if port=$(wait_import_ready 2>$src_output); then
  { sleep 1; : | do_export $port; } >>$src_output 2>&1 & exppid=$!
fi
checkpids $exppid $imppid || \
  err 'Listening with timeout failed when it should not'

start_test 'Connect timeout'
# Setting lower timeout as nothing will be listening on port 0
: | connect_timeout=1 do_export 0 &>$src_output & exppid=$!
checkpids $exppid && err 'Connection did not time out when it should'

start_test 'No compression'
compress=none do_import > $statusdir/recv-nocompr 2>$dst_output & imppid=$!
if port=$(wait_import_ready 2>$src_output); then
  compress=none do_export $port < $testdata >>$src_output 2>&1 & exppid=$!
fi
checkpids $exppid $imppid || err 'An error occurred'
cmp $testdata $statusdir/recv-nocompr || \
  err 'Received data does not match input'

start_test 'Compression mismatch A'
compress=none do_import > $statusdir/recv-miscompr 2>$dst_output & imppid=$!
if port=$(wait_import_ready 2>$src_output); then
  compress=gzip do_export $port < $testdata >>$src_output 2>&1 & exppid=$!
fi
checkpids $exppid $imppid || err 'An error occurred'
cmp -s $testdata $statusdir/recv-miscompr && \
  err 'Received data matches input when it should not'

start_test 'Compression mismatch B'
compress=gzip do_import > $statusdir/recv-miscompr2 2>$dst_output & imppid=$!
if port=$(wait_import_ready 2>$src_output); then
  compress=none do_export $port < $testdata >>$src_output 2>&1 & exppid=$!
fi
checkpids $exppid $imppid && err 'Did not fail when it should'
cmp -s $testdata $statusdir/recv-miscompr2 && \
  err 'Received data matches input when it should not'

start_test 'Large transfer'
do_import > $statusdir/recv-large 2>$dst_output & imppid=$!
if port=$(wait_import_ready 2>$src_output); then
  do_export $port < $largetestdata >>$src_output 2>&1 & exppid=$!
fi
checkpids $exppid $imppid || err 'An error occurred'
cmp $largetestdata $statusdir/recv-large || \
  err 'Received data does not match input'

exit 0
