#!/bin/bash
qemu-system-x86_64 -kernel bzImage -machine type=q35,accel=kvm -m 512 -smp 2 -net nic -net user
