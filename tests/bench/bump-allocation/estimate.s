.intel_syntax noprefix
.text
.globl allocation_hit_24
# Shape only: offsets and registers are placeholders, not an executable allocator.
allocation_hit_24:
 mov r10, QWORD PTR [rip + tls_offset_descriptor]
 mov r10, QWORD PTR fs:[r10]
 test r10, r10
 jz slow
 cmp BYTE PTR [r10 + 64], 0
 je slow
 mov r11, QWORD PTR [rdi + 8]
 test r11, r11
 jz slow
 cmp QWORD PTR [r11 + 16], 0
 je slow
 mov r11, QWORD PTR [r10 + 48]
 mov rax, QWORD PTR [r11 + 32]
 test rax, rax
 jz slow
 lea rdx, [rax + 24]
 cmp rdx, QWORD PTR [r11 + 40]
 ja slow
 mov QWORD PTR [r11 + 32], rdx
 mov QWORD PTR [rax + 8], 0
 mov QWORD PTR [rax + 16], 0
 mov QWORD PTR [rax], rdi
 ret
slow:
 ret
.data
tls_offset_descriptor: .quad 0
