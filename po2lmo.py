import sys
import struct

def jenkins_hash(key):
    hash_val = 0
    for char in key:
        hash_val += ord(char)
        hash_val += (hash_val << 10)
        hash_val &= 0xFFFFFFFF
        hash_val ^= (hash_val >> 6)
    hash_val += (hash_val << 3)
    hash_val &= 0xFFFFFFFF
    hash_val ^= (hash_val >> 11)
    hash_val += (hash_val << 15)
    return hash_val & 0xFFFFFFFF

def parse_po(filename):
    entries = []
    with open(filename, 'r', encoding='utf-8') as f:
        msgid = ""
        msgstr = ""
        in_msgid = False
        in_msgstr = False
        for line in f:
            line = line.strip()
            if line.startswith("msgid "):
                if msgid and msgstr:
                    entries.append((msgid, msgstr))
                msgid = line[7:-1]
                in_msgid = True
                in_msgstr = False
            elif line.startswith("msgstr "):
                msgstr = line[8:-1]
                in_msgid = False
                in_msgstr = True
            elif line.startswith('"') and line.endswith('"'):
                if in_msgid:
                    msgid += line[1:-1]
                elif in_msgstr:
                    msgstr += line[1:-1]
        if msgid and msgstr:
            entries.append((msgid, msgstr))
    return entries

def write_lmo(entries, out_filename):
    entries = [(k, v) for k, v in entries if k and v]
    entries.sort(key=lambda x: jenkins_hash(x[0]))
    
    string_data = b""
    index_data = b""
    
    for k, v in entries:
        hash_val = jenkins_hash(k)
        v_bytes = v.replace('\\n', '\n').replace('\\"', '"').encode('utf-8')
        val_offset = len(string_data)
        val_len = len(v_bytes)
        string_data += v_bytes + b'\0'
        
        index_data += struct.pack(">IIII", hash_val, len(k.encode('utf-8')), val_offset, val_len)
        
    num_entries = len(entries)
    offset_to_index = len(string_data)
    
    header = struct.pack(">IIII", 0x1A4F4D4C, 1, num_entries, offset_to_index)
    
    with open(out_filename, 'wb') as f:
        f.write(header)
        f.write(string_data)
        f.write(index_data)

if __name__ == "__main__":
    entries = parse_po(sys.argv[1])
    write_lmo(entries, sys.argv[2])
