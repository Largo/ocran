# Writes stage0.rb as a C string literal header (static const char
# ocran_stage0[]) for ocran_main.c:
#
#   ruby native/gen-stage0-header.rb native/stage0.rb OUT.h
#
# Only printable ASCII is emitted as is; everything else (and '?', so no
# trigraph can form) is an octal escape.
src, out = ARGV
abort "usage: gen-stage0-header.rb stage0.rb OUT.h" unless out
lines = File.binread(src).each_line.map do |line|
  body = line.bytes.map do |b|
    if b == 0x22 || b == 0x5c then "\\" + b.chr
    elsif b >= 0x20 && b < 0x7f && b != 0x3f then b.chr
    else format("\\%03o", b)
    end
  end.join
  "  \"#{body}\""
end
File.write(out, "/* generated from native/stage0.rb */\n" \
                "static const char ocran_stage0[] =\n#{lines.join("\n")};\n")
