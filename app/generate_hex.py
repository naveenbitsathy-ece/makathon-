import os
import shutil

def bin_to_hex():
    bin_path = 'dna_decimal_app.bin'
    hex_path = 'dna_decimal_app.hex'
    
    with open(bin_path, 'rb') as f:
        data = f.read()
    
    words = []
    for i in range(0, len(data), 4):
        chunk = data[i:i+4]
        if len(chunk) < 4:
            chunk = chunk + b'\x00' * (4 - len(chunk))
        val = int.from_bytes(chunk, 'little')
        words.append(f"{val:08x}")
    
    while len(words) < 2048:
        words.append("00000000")
        
    with open(hex_path, 'w') as f:
        for w in words[:2048]:
            f.write(w + "\n")
            
    print(f"dna_decimal_app.bin size: {len(data)} bytes ({len(data)/8192*100:.1f}% of 8KB RAM)")
    print(f"dna_decimal_app.hex generated: {len(words[:2048])} words")

    # Also copy to root directory as dna_decimal_app.bin and dna_decimal_app.hex
    shutil.copyfile(bin_path, os.path.join('..', bin_path))
    shutil.copyfile(hex_path, os.path.join('..', hex_path))
    print(f"Copied {bin_path} and {hex_path} to root workspace directory.")

if __name__ == '__main__':
    bin_to_hex()
