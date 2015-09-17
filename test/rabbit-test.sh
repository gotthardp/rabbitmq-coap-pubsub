#!/bin/sh
CTL=$1

$CTL add_user "anonymous" ''
$CTL set_permissions -p / "anonymous" ".*" ".*" ".*"
