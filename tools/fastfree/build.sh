#!/bin/sh
# Assemble FASTFREE.COM with GNU binutils (no nasm needed).
set -e
cd "$(dirname "$0")"
as --32 -o fastfree.o fastfree.s
ld -m elf_i386 -Ttext=0x100 --oformat binary -o FASTFREE.COM fastfree.o
rm -f fastfree.o
ls -l FASTFREE.COM
