// ============================================================================
// File:         main.c
// Project:      DNA Sequence Analyzer with Decimal Match Percentage Display
// Target:       Real Digital Boolean FPGA Board (Spartan-7 XC7S50-CSGA324-1)
// Mode 1:       Whole Sequence Matching with Decimal Match Percentage:
//                 - LCD Row 1: MATCH or MISMATCH
//                 - LCD Row 2: MATCH: XX.XX%
//                 - Left 7-segment (DISP1): Strict match indicator (1 or 0)
//                 - Right 7-segment (DISP2): Match percentage with decimal point
//                   (100.0 for 100%, XX.YY for <100%)
// Mode 2:       Motif Detection (Preserved Unchanged):
//                 - Total motif occurrence count (overlapping included)
//                 - All zero-based starting positions
//                 - Left 7-segment shows count, Right 7-segment cycles positions
// ============================================================================

#include <stdint.h>
#include <stdbool.h>

#define REG(addr) (*(volatile uint32_t *)(addr))

// Hardware MMIO Base Addresses
#define UART_DATA             REG(0x20000000)
#define UART_STATUS           REG(0x20000004)
#define LED_REG               REG(0x30000000)

// DNA Hardware Accelerator MMIO (0x4000_0000)
#define DNA_REF_DATA          REG(0x40000000)
#define DNA_MOTIF_DATA        REG(0x40000004)
#define DNA_CONFIG            REG(0x40000008)
#define DNA_CONTROL           REG(0x4000000C)
#define DNA_STATUS            REG(0x40000010)
#define DNA_MATCH_COUNT       REG(0x40000014)
#define DNA_POS_INDEX         REG(0x40000018)
#define DNA_POS_DATA          REG(0x4000001C)

// Seven-Segment Display Controller MMIO (0x5000_0000)
#define SEVENSEG_VAL0         REG(0x50000000) // DISP1 (Left display group: Digits 0..3)
#define SEVENSEG_VAL1         REG(0x50000004) // DISP2 (Right display group: Digits 4..7)
#define SEVENSEG_CTRL         REG(0x50000008) // [7:0]=blank mask, [15:8]=DP mask
#define SEVENSEG_CYCLE_CTRL   REG(0x5000000C) // [0]=cycle_en, [7:4]=num_pos, [8]=restart
#define SEVENSEG_CYCLE_PERIOD REG(0x50000010) // Clock cycles per position step
#define SEVENSEG_POS_TAB(i)   REG(0x50000020 + ((i) * 4)) // Position table entries 0..15

// OpenCores I2C Master Registers (0x6000_0000 via Wishbone bridge)
#define I2C_PRER_LO           REG(0x60000000) // Prescaler low byte
#define I2C_PRER_HI           REG(0x60000004) // Prescaler high byte
#define I2C_CTR               REG(0x60000008) // Control register
#define I2C_TXR               REG(0x6000000C) // Transmit register (write)
#define I2C_RXR               REG(0x6000000C) // Receive register (read)
#define I2C_CR                REG(0x60000010) // Command register (write)
#define I2C_SR                REG(0x60000010) // Status register (read)

// I2C Command / Status Register bits
#define I2C_CR_STA            0x80
#define I2C_CR_STO            0x40
#define I2C_CR_RD             0x20
#define I2C_CR_WR             0x10
#define I2C_CR_ACK            0x08
#define I2C_CR_IACK           0x01

#define I2C_SR_RXACK          0x80
#define I2C_SR_BUSY           0x40
#define I2C_SR_AL             0x20
#define I2C_SR_TIP            0x02
#define I2C_SR_IF             0x01

// Target I2C Slave Address (verified physical LCD backpack)
#define LCD_I2C_ADDR          0x27

// PCF8574 Output Pin Mapping:
//   P0: RS (0 = Command, 1 = Data)
//   P1: RW (0 = Write, 1 = Read)
//   P2: EN (Enable strobe)
//   P3: Backlight (1 = ON, 0 = OFF)
//   P4..P7: D4..D7
#define PIN_RS                (1 << 0)
#define PIN_RW                (1 << 1)
#define PIN_EN                (1 << 2)
#define PIN_BACKLIGHT         (1 << 3)

// UART Status Register bits
#define UART_TX_BUSY          0x01
#define UART_RX_VALID         0x02

// DNA Control / Status bits
#define DNA_STATUS_BUSY       0x01
#define DNA_STATUS_DONE       0x02

#define DNA_START             0x01
#define DNA_RESET_PTRS        0x02
#define DNA_MODE_SEQ          (0 << 2) // Mode 0: Whole sequence matching
#define DNA_MODE_MOTIF        (1 << 2) // Mode 1: Motif detection

// LED Status Patterns
#define LED_APP_MENU          0x0010
#define LED_WAIT_REF          0x0020
#define LED_WAIT_QUERY        0x0040
#define LED_PROCESSING        0x0080
#define LED_SEQ_FOUND         0x0101
#define LED_SEQ_NOT_FOUND     0x0100
#define LED_MOTIF_COMPLETE    0x0200

// ----------------------------------------------------------------------------
// Low-Level Freestanding Multiplication (Eliminates __mulsi3 dependency)
// ----------------------------------------------------------------------------
int __mulsi3(int a, int b) {
    int res = 0;
    unsigned int ub = (unsigned int)b;
    while (ub) {
        if (ub & 1) res += a;
        a <<= 1;
        ub >>= 1;
    }
    return res;
}

// ----------------------------------------------------------------------------
// Low-Level Freestanding Delays (No software division library dependencies)
// ----------------------------------------------------------------------------
static void delay_cycles(uint32_t count) {
    for (volatile uint32_t i = 0; i < count; i++) {
        __asm__ volatile ("nop");
    }
}

static void delay_us(uint32_t us) {
    delay_cycles(us * 15);
}

static void delay_ms(uint32_t ms) {
    delay_cycles(ms * 12000);
}

// ----------------------------------------------------------------------------
// Lightweight Integer Arithmetic Helpers (Eliminates __udivsi3 dependency)
// ----------------------------------------------------------------------------
static unsigned int udiv(unsigned int num, unsigned int den) {
    if (den == 0) return 0;
    unsigned int quot = 0;
    while (num >= den) {
        unsigned int temp_den = den;
        unsigned int mult = 1;
        while ((num >> 1) >= temp_den) {
            temp_den <<= 1;
            mult <<= 1;
        }
        num -= temp_den;
        quot += mult;
    }
    return quot;
}

static unsigned int umod(unsigned int num, unsigned int den) {
    if (den == 0) return 0;
    while (num >= den) {
        unsigned int temp_den = den;
        while ((num >> 1) >= temp_den) {
            temp_den <<= 1;
        }
        num -= temp_den;
    }
    return num;
}

static void uint_to_str(unsigned int n, char *buf) {
    if (n == 0) {
        buf[0] = '0';
        buf[1] = '\0';
        return;
    }
    char rev[12];
    int len = 0;
    while (n > 0) {
        unsigned int q = udiv(n, 10);
        unsigned int r = umod(n, 10);
        rev[len++] = (char)('0' + r);
        n = q;
    }
    for (int i = 0; i < len; i++) {
        buf[i] = rev[len - 1 - i];
    }
    buf[len] = '\0';
}

// ----------------------------------------------------------------------------
// Low-Level UART Communication
// ----------------------------------------------------------------------------
static char uart_getc(void) {
    while (!(UART_STATUS & UART_RX_VALID))
        ;
    return (char)(UART_DATA & 0xFF);
}

static void uart_putc(char c) {
    while (UART_STATUS & UART_TX_BUSY)
        ;
    UART_DATA = (uint32_t)(uint8_t)c;
}

static void uart_puts(const char *s) {
    while (*s) {
        if (*s == '\n') {
            while (UART_STATUS & UART_TX_BUSY)
                ;
            UART_DATA = '\r';
        }
        while (UART_STATUS & UART_TX_BUSY)
            ;
        UART_DATA = (uint32_t)(uint8_t)*s++;
    }
}

static void uart_put_uint(unsigned int n) {
    char buf[12];
    uint_to_str(n, buf);
    uart_puts(buf);
}

// ----------------------------------------------------------------------------
// Seven-Segment Display Helpers (0x5000_0000)
// Preserving exact verified layout and behavior from baseline
// ----------------------------------------------------------------------------
static unsigned int to_bcd4(unsigned int n) {
    unsigned int d3 = 0, d2 = 0, d1 = 0, d0 = 0;
    while (n >= 1000) {
        n -= 1000;
        d3++;
    }
    while (n >= 100) {
        n -= 100;
        d2++;
    }
    while (n >= 10) {
        n -= 10;
        d1++;
    }
    d0 = n;
    if (d3 > 9) d3 = 9;
    return (d0 & 0xF) | ((d1 & 0xF) << 4) | ((d2 & 0xF) << 8) | ((d3 & 0xF) << 12);
}

static void seg7_clear(void) {
    SEVENSEG_CYCLE_CTRL = 0;
    SEVENSEG_VAL0 = 0;
    SEVENSEG_VAL1 = 0;
    SEVENSEG_CTRL = 0xFF; // Blank all 8 digits
}

// Mode 1: Left group displays match indicator (1 or 0), Right group displays percentage
static void seg7_show_mode1_decimal(int matched, unsigned int pct_hundredths) {
    SEVENSEG_CYCLE_CTRL = 0; // Hardware cycler disabled in Mode 1

    // Left display group (DISP1 / Digits 0..3):
    // Preserved: Digit 0 displays 1 for match, 0 for mismatch. Digits 1..3 blanked.
    SEVENSEG_VAL0 = (matched ? 1 : 0);

    // Right display group (DISP2 / Digits 4..7):
    // Digits from left to right: Digit 7, Digit 6, Digit 5, Digit 4
    if (pct_hundredths >= 10000) {
        // 100.00% -> display "100.0"
        // Digit 7 = 1, Digit 6 = 0, Digit 5 = 0 (with DP on Digit 5), Digit 4 = 0
        SEVENSEG_VAL1 = 0x1000;
        // Digit 0 enabled, Digits 1..3 blanked (blank_reg[3:0] = 0xE)
        // Digits 4..7 enabled (blank_reg[7:4] = 0x0) -> blank_reg = 0x0E
        // Decimal point on Digit 5: dp_reg bit 5 = 1 (1 << 5 = 0x20)
        SEVENSEG_CTRL = (0x20 << 8) | 0x0E;
    } else {
        // < 100.00% (e.g. 75.00%, 66.67%, 33.33%, 0.00%)
        // Format as XX.YY on 4 digits:
        // Digit 7 = tens of whole (e.g. 7 in 75, 0 in 00)
        // Digit 6 = units of whole (e.g. 5 in 75, 0 in 00) -> with DP!
        // Digit 5 = tenths of fraction (e.g. 0 in 00, 6 in 67)
        // Digit 4 = hundredths of fraction (e.g. 0 in 00, 7 in 67)
        unsigned int whole = udiv(pct_hundredths, 100);
        unsigned int frac  = umod(pct_hundredths, 100);

        unsigned int d7 = udiv(whole, 10);
        unsigned int d6 = umod(whole, 10);
        unsigned int d5 = udiv(frac, 10);
        unsigned int d4 = umod(frac, 10);

        SEVENSEG_VAL1 = ((d7 & 0xF) << 12) | ((d6 & 0xF) << 8) | ((d5 & 0xF) << 4) | (d4 & 0xF);

        // Digit 0 enabled, Digits 1..3 blanked, Digits 4..7 enabled -> blank_reg = 0x0E
        // Decimal point on Digit 6: dp_reg bit 6 = 1 (1 << 6 = 0x40)
        SEVENSEG_CTRL = (0x40 << 8) | 0x0E;
    }
}

// Mode 2: Preserved completely unchanged from baseline
static void seg7_show_mode2(unsigned int count, const unsigned int *positions, unsigned int num_pos) {
    if (count == 0) {
        // Zero matches:
        // Left display (DISP1): count 0000
        // Right display (DISP2): idle/no-position '----' (0xFFFF)
        SEVENSEG_CYCLE_CTRL = 0;
        SEVENSEG_VAL0 = 0x0000;
        SEVENSEG_VAL1 = 0xFFFF;
        SEVENSEG_CTRL = 0x00; // All 8 digits enabled (no blanking)
    } else if (count == 1 || num_pos <= 1) {
        // Single match:
        // Left display: count 0001
        // Right display: single starting position with leading zeros (e.g. 0000)
        unsigned int p = (num_pos > 0) ? positions[0] : 0;
        SEVENSEG_CYCLE_CTRL = 0;
        SEVENSEG_VAL0 = to_bcd4(count);
        SEVENSEG_VAL1 = to_bcd4(p);
        SEVENSEG_CTRL = 0x00; // All 8 digits enabled
    } else {
        // Multiple matches:
        // Left display (DISP1): total count with leading zeros (e.g. 0004) throughout
        // Right display (DISP2): cycles through all match positions at ~1 sec per position
        unsigned int n = (num_pos > 16) ? 16 : num_pos;
        SEVENSEG_VAL0 = to_bcd4(count);
        for (unsigned int i = 0; i < n; i++) {
            SEVENSEG_POS_TAB(i) = to_bcd4(positions[i]);
        }
        SEVENSEG_VAL1 = to_bcd4(positions[0]);
        SEVENSEG_CYCLE_CTRL = 1 | (n << 4) | (1 << 8); // cycle_en=1, num_pos=n, restart=1
        SEVENSEG_CTRL = 0x00; // All 8 digits enabled
    }
}

// ----------------------------------------------------------------------------
// OpenCores I2C Master Low-Level Drivers (0x6000_0000)
// Reused from verified diagnostic implementation
// ----------------------------------------------------------------------------
static void i2c_init_hardware(void) {
    // 100 MHz clock, 25 kHz bus frequency:
    // PRER = 100_000_000 / (5 * 25_000) - 1 = 799 = 0x031F
    I2C_PRER_LO = 0x1F;
    I2C_PRER_HI = 0x03;
    I2C_CTR     = 0x80; // Core enable (bit 7)
}

static bool pcf8574_write(uint8_t val) {
    // 1. Send device address with Write bit (0) + START condition
    I2C_TXR = (uint32_t)((LCD_I2C_ADDR << 1) & 0xFE);
    I2C_CR  = (I2C_CR_STA | I2C_CR_WR);

    uint32_t timeout = 50000;
    while ((I2C_SR & I2C_SR_TIP) && --timeout)
        ;
    if (timeout == 0) return false;

    // Check for NACK on slave address
    if (I2C_SR & I2C_SR_RXACK) {
        I2C_CR = I2C_CR_STO;
        timeout = 50000;
        while ((I2C_SR & I2C_SR_TIP) && --timeout)
            ;
        return false;
    }

    // 2. Send 8-bit expander byte + STOP condition
    I2C_TXR = (uint32_t)val;
    I2C_CR  = (I2C_CR_WR | I2C_CR_STO);

    timeout = 50000;
    while ((I2C_SR & I2C_SR_TIP) && --timeout)
        ;
    if (timeout == 0) return false;

    return ((I2C_SR & I2C_SR_RXACK) == 0);
}

// ----------------------------------------------------------------------------
// HD44780 4-Bit Protocol via PCF8574 Expander
// ----------------------------------------------------------------------------
static void lcd_write_nibble(uint8_t nibble, uint8_t control_flags) {
    uint8_t base = (uint8_t)((nibble << 4) | control_flags | PIN_BACKLIGHT);

    // Step 1: Enable HIGH (setup data lines)
    pcf8574_write(base | PIN_EN);
    delay_us(50);

    // Step 2: Enable LOW (falling edge latches data into LCD controller)
    pcf8574_write(base & ~PIN_EN);
    delay_us(50);
}

static void lcd_send_byte(uint8_t val, uint8_t rs_flag) {
    uint8_t high_nibble = (val >> 4) & 0x0F;
    uint8_t low_nibble  = val & 0x0F;

    lcd_write_nibble(high_nibble, rs_flag);
    lcd_write_nibble(low_nibble,  rs_flag);
}

static void lcd_command(uint8_t cmd) {
    lcd_send_byte(cmd, 0); // RS = 0 for command
    if (cmd == 0x01 || cmd == 0x02) {
        delay_ms(3); // Clear display & Return home require up to 2 ms
    } else {
        delay_us(50);
    }
}

static void lcd_data(uint8_t ch) {
    lcd_send_byte(ch, PIN_RS); // RS = 1 for character data
    delay_us(50);
}

static bool lcd_init_16x2(void) {
    delay_ms(60);
    lcd_write_nibble(0x03, 0);
    delay_ms(5);
    lcd_write_nibble(0x03, 0);
    delay_us(200);
    lcd_write_nibble(0x03, 0);
    delay_us(200);
    lcd_write_nibble(0x02, 0);
    delay_ms(2);
    lcd_command(0x28); // 4-bit mode, 2 display lines, 5x8 font
    lcd_command(0x08); // Display OFF
    lcd_command(0x01); // Clear display
    delay_ms(3);
    lcd_command(0x06); // Auto-increment cursor, no shift
    lcd_command(0x0C); // Display ON, cursor OFF, blink OFF
    return true;
}

static void lcd_set_cursor(uint8_t row, uint8_t col) {
    uint8_t base_addr = (row == 0) ? 0x80 : 0xC0;
    if (col > 15) col = 15;
    lcd_command(base_addr + col);
}

static void lcd_print_row(uint8_t row, const char *str) {
    lcd_set_cursor(row, 0);
    uint8_t col = 0;
    while (*str && col < 16) {
        lcd_data((uint8_t)*str++);
        col++;
    }
    // Pad remainder of row with spaces to overwrite any previous characters cleanly
    while (col < 16) {
        lcd_data(' ');
        col++;
    }
}

static void lcd_show_menu_screen(void) {
    lcd_print_row(0, "DNA ANALYZER");
    lcd_print_row(1, "1:MATCH  2:MOTIF");
}

// ----------------------------------------------------------------------------
// LCD Input-Sequence Display with Paging (Section 6)
// ----------------------------------------------------------------------------
static void lcd_display_input_sequences(int mode, const char *ref, int ref_len,
                                       const char *second, int second_len) {
    const char *second_tag = (mode == 1) ? "QRY:" : "MTF:";

    // If both sequences fit on one screen without truncation (<= 12 chars each):
    if (ref_len <= 12 && second_len <= 12) {
        char line1[17];
        char line2[17];
        int idx1 = 0;
        int idx2 = 0;

        line1[idx1++] = 'R'; line1[idx1++] = 'E'; line1[idx1++] = 'F'; line1[idx1++] = ':';
        for (int i = 0; i < ref_len; i++) line1[idx1++] = ref[i];
        while (idx1 < 16) line1[idx1++] = ' ';
        line1[16] = '\0';

        line2[idx2++] = second_tag[0]; line2[idx2++] = second_tag[1];
        line2[idx2++] = second_tag[2]; line2[idx2++] = second_tag[3];
        for (int i = 0; i < second_len; i++) line2[idx2++] = second[i];
        while (idx2 < 16) line2[idx2++] = ' ';
        line2[16] = '\0';

        lcd_print_row(0, line1);
        lcd_print_row(1, line2);
        delay_ms(1500);
        return;
    }

    // Long sequence paging: Display 12-base windows sequentially
    int max_len = (ref_len > second_len) ? ref_len : second_len;
    int num_pages = 0;
    int rem = max_len;
    while (rem > 0) {
        num_pages++;
        rem = (rem > 12) ? (rem - 12) : 0;
    }
    if (num_pages == 0) num_pages = 1;

    for (int p = 0; p < num_pages; p++) {
        char line1[17];
        char line2[17];
        int start_idx = p * 12;

        int idx1 = 0;
        line1[idx1++] = 'R'; line1[idx1++] = 'E'; line1[idx1++] = 'F'; line1[idx1++] = ':';
        for (int i = 0; i < 12; i++) {
            int pos = start_idx + i;
            if (pos < ref_len) {
                line1[idx1++] = ref[pos];
            } else {
                line1[idx1++] = ' ';
            }
        }
        line1[16] = '\0';

        int idx2 = 0;
        line2[idx2++] = second_tag[0]; line2[idx2++] = second_tag[1];
        line2[idx2++] = second_tag[2]; line2[idx2++] = second_tag[3];
        for (int i = 0; i < 12; i++) {
            int pos = start_idx + i;
            if (pos < second_len) {
                line2[idx2++] = second[pos];
            } else {
                line2[idx2++] = ' ';
            }
        }
        line2[16] = '\0';

        lcd_print_row(0, line1);
        lcd_print_row(1, line2);
        delay_ms(1500);
    }
}

// ----------------------------------------------------------------------------
// Mode 1: Decimal Percentage LCD Output (Section 2)
// Row 1: MATCH or MISMATCH (only)
// Row 2: MATCH: XX.XX%
// ----------------------------------------------------------------------------
static void lcd_show_mode1_decimal_result(int matched, unsigned int pct_hundredths) {
    // Row 1: exactly MATCH or MISMATCH
    if (matched) {
        lcd_print_row(0, "MATCH");
    } else {
        lcd_print_row(0, "MISMATCH");
    }

    // Row 2: MATCH: XX.XX%
    unsigned int whole = udiv(pct_hundredths, 100);
    unsigned int frac  = umod(pct_hundredths, 100);

    char row2[17];
    int idx = 0;
    const char *prefix = "MATCH: ";
    while (*prefix) row2[idx++] = *prefix++;

    char wbuf[6];
    uint_to_str(whole, wbuf);
    char *wp = wbuf;
    while (*wp) row2[idx++] = *wp++;

    row2[idx++] = '.';
    row2[idx++] = (char)('0' + udiv(frac, 10));
    row2[idx++] = (char)('0' + umod(frac, 10));
    row2[idx++] = '%';
    row2[idx] = '\0';

    lcd_print_row(1, row2);
}

// ----------------------------------------------------------------------------
// Mode 2: Preserved Completely Unchanged (Section 5)
// ----------------------------------------------------------------------------
static void lcd_show_mode2_result(unsigned int match_count,
                                  const unsigned int *positions,
                                  unsigned int num_recorded) {
    char row1[17];
    int idx1 = 0;
    const char *tag1 = "MATCH COUNT: ";
    while (*tag1) row1[idx1++] = *tag1++;
    char count_str[12];
    uint_to_str(match_count, count_str);
    char *cp = count_str;
    while (*cp && idx1 < 16) row1[idx1++] = *cp++;
    while (idx1 < 16) row1[idx1++] = ' ';
    row1[16] = '\0';

    lcd_print_row(0, row1);

    if (match_count == 0) {
        lcd_print_row(1, "NO MATCHES");
        return;
    }

    char full_pos_str[128];
    int full_len = 0;
    for (unsigned int i = 0; i < num_recorded; i++) {
        char pstr[12];
        uint_to_str(positions[i], pstr);
        char *pp = pstr;
        while (*pp && full_len < 120) full_pos_str[full_len++] = *pp++;
        if (i + 1 < num_recorded && full_len < 120) {
            full_pos_str[full_len++] = ',';
        }
    }
    full_pos_str[full_len] = '\0';

    if (full_len <= 11) {
        char row2[17];
        int idx2 = 0;
        row2[idx2++] = 'P'; row2[idx2++] = 'O'; row2[idx2++] = 'S';
        row2[idx2++] = ':'; row2[idx2++] = ' ';
        for (int i = 0; i < full_len; i++) row2[idx2++] = full_pos_str[i];
        while (idx2 < 16) row2[idx2++] = ' ';
        row2[16] = '\0';
        lcd_print_row(1, row2);
    } else {
        int offset = 0;
        while (offset < full_len) {
            char row2[17];
            int idx2 = 0;
            row2[idx2++] = 'P'; row2[idx2++] = 'O'; row2[idx2++] = 'S';
            row2[idx2++] = ':'; row2[idx2++] = ' ';

            int avail = 11;
            int remaining = full_len - offset;
            bool more = (remaining > avail);

            int chunk = more ? (avail - 2) : remaining;
            for (int i = 0; i < chunk; i++) {
                row2[idx2++] = full_pos_str[offset + i];
            }
            if (more) {
                row2[idx2++] = '.';
                row2[idx2++] = '.';
            }
            while (idx2 < 16) row2[idx2++] = ' ';
            row2[16] = '\0';

            lcd_print_row(1, row2);
            delay_ms(1500);

            offset += chunk;
        }
    }
}

// ----------------------------------------------------------------------------
// Terminal Line Reading with Validation, Normalization & Backspace Support
// ----------------------------------------------------------------------------
static int read_dna_sequence(char *buf, int max_len) {
    int len = 0;

    while (1) {
        char c = uart_getc();

        if (c == '\r' || c == '\n') {
            if (len > 0) {
                uart_puts("\r\n");
                buf[len] = '\0';
                return len;
            }
            continue; // Reject empty sequence: must have at least 1 valid base
        }

        if (c == '\b' || c == 127) {
            if (len > 0) {
                len--;
                uart_puts("\b \b");
            }
            continue;
        }

        if (c >= 'a' && c <= 'z') {
            c -= ('a' - 'A');
        }

        if (c == 'A' || c == 'C' || c == 'G' || c == 'T') {
            if (len < max_len) {
                buf[len++] = c;
                uart_putc(c);
            }
        }
    }
}

static char read_choice(void) {
    while (1) {
        char c = uart_getc();
        if (c == '1' || c == '2') {
            uart_putc(c);
            uart_puts("\r\n\n");
            return c;
        }
    }
}

// ----------------------------------------------------------------------------
// Base Encoding (A=00, C=01, G=10, T=11)
// ----------------------------------------------------------------------------
static inline unsigned int encode_base(char c) {
    switch (c) {
        case 'A': return 0x0;
        case 'C': return 0x1;
        case 'G': return 0x2;
        case 'T': return 0x3;
        default:  return 0x0;
    }
}

// ----------------------------------------------------------------------------
// Hardware Accelerator Execution via MMIO (0x4000_0000)
// ----------------------------------------------------------------------------
static void run_dna_accelerator(int mode, const char *target, int target_len,
                                const char *query, int query_len,
                                unsigned int *out_match_count) {
    unsigned int mode_bit = (mode == 1) ? DNA_MODE_MOTIF : DNA_MODE_SEQ;
    DNA_CONTROL = mode_bit | DNA_RESET_PTRS;

    int target_words = (target_len + 15) >> 4;
    for (int w = 0; w < target_words; w++) {
        unsigned int word = 0;
        for (int b = 0; b < 16; b++) {
            int base_idx = (w << 4) + b;
            unsigned int code = 0;
            if (base_idx < target_len) {
                code = encode_base(target[base_idx]);
            }
            word |= (code << (b << 1));
        }
        DNA_REF_DATA = word;
    }

    int query_words = (query_len + 15) >> 4;
    for (int w = 0; w < query_words; w++) {
        unsigned int word = 0;
        for (int b = 0; b < 16; b++) {
            int base_idx = (w << 4) + b;
            unsigned int code = 0;
            if (base_idx < query_len) {
                code = encode_base(query[base_idx]);
            }
            word |= (code << (b << 1));
        }
        DNA_MOTIF_DATA = word;
    }

    DNA_CONFIG = ((unsigned int)target_len & 0xFF) | (((unsigned int)query_len & 0xFF) << 8);
    DNA_CONTROL = mode_bit | DNA_START;

    while (!(DNA_STATUS & DNA_STATUS_DONE))
        ;

    *out_match_count = DNA_MATCH_COUNT & 0xFF;
}

// ----------------------------------------------------------------------------
// Main Application Loop
// ----------------------------------------------------------------------------
int main(void) {
    char ref_seq[130];
    char query_seq[130];

    LED_REG = LED_APP_MENU;
    seg7_clear();

    i2c_init_hardware();
    lcd_init_16x2();
    lcd_show_menu_screen();

    while (1) {
        LED_REG = LED_APP_MENU;

        uart_puts("========================================\n");
        uart_puts("DNA SEQUENCE ANALYZER\n");
        uart_puts("1. Sequence Matching\n");
        uart_puts("2. Motif Detection\n");
        uart_puts("Select mode: ");

        char choice = read_choice();

        if (choice == '1') {
            // ================================================================
            // MODE 1 — SEQUENCE MATCHING WITH DECIMAL MATCH PERCENTAGE
            // ================================================================
            LED_REG = LED_WAIT_REF;
            uart_puts("Enter reference DNA sequence: ");
            int ref_len = read_dna_sequence(ref_seq, 128);

            LED_REG = LED_WAIT_QUERY;
            uart_puts("Enter query DNA sequence: ");
            int query_len = read_dna_sequence(query_seq, 128);

            // Display accepted sequences on UART
            uart_puts("\nAccepted inputs:\n");
            uart_puts("Reference: ");
            uart_puts(ref_seq);
            uart_puts("\nQuery:     ");
            uart_puts(query_seq);
            uart_puts("\n\n");

            // Display inputs on LCD immediately with paging for long inputs
            lcd_display_input_sequences(1, ref_seq, ref_len, query_seq, query_len);

            LED_REG = LED_PROCESSING;
            uart_puts("Processing...\n\n");

            // Safe calculation of matching positions & match percentage
            // Formula: percentage = (matching_positions / max(ref_len, query_len)) * 100
            // Integer hundredths: (matching_positions * 10000 + denominator / 2) / denominator
            int min_len = (ref_len < query_len) ? ref_len : query_len;
            unsigned int matching_positions = 0;
            for (int i = 0; i < min_len; i++) {
                if (ref_seq[i] == query_seq[i]) {
                    matching_positions++;
                }
            }

            unsigned int denominator = (ref_len > query_len) ? (unsigned int)ref_len : (unsigned int)query_len;
            unsigned int pct_hundredths = 0;
            if (denominator > 0) {
                unsigned int num = matching_positions * 10000 + (denominator >> 1);
                pct_hundredths = udiv(num, denominator);
            }
            if (pct_hundredths > 10000) pct_hundredths = 10000;

            // Strict equality evaluation:
            // MATCH requires identical lengths AND every base to match
            int strict_match = (ref_len == query_len) && (matching_positions == (unsigned int)ref_len);

            // Also invoke hardware accelerator for verification
            unsigned int hw_match = 0;
            run_dna_accelerator(0, ref_seq, ref_len, query_seq, query_len, &hw_match);

            unsigned int whole = udiv(pct_hundredths, 100);
            unsigned int frac  = umod(pct_hundredths, 100);

            // Print full information to PuTTY as specified in Section 6
            uart_puts("========================================\n");
            uart_puts("MODE 1 RESULT:\n");
            uart_puts("Reference: ");
            uart_puts(ref_seq);
            uart_puts("\nQuery:     ");
            uart_puts(query_seq);
            uart_puts("\nResult: ");
            if (strict_match) {
                LED_REG = LED_SEQ_FOUND;
                uart_puts("MATCH\n");
            } else {
                LED_REG = LED_SEQ_NOT_FOUND;
                uart_puts("MISMATCH\n");
            }
            uart_puts("Matching positions: ");
            uart_put_uint(matching_positions);
            uart_puts("\nReference length: ");
            uart_put_uint((unsigned int)ref_len);
            uart_puts("\nQuery length: ");
            uart_put_uint((unsigned int)query_len);
            uart_puts("\nMatch percentage: ");
            uart_put_uint(whole);
            uart_putc('.');
            uart_putc((char)('0' + udiv(frac, 10)));
            uart_putc((char)('0' + umod(frac, 10)));
            uart_puts("%\n");
            uart_puts("========================================\n\n");

            // Update on-board seven-segment display and 16x2 I2C LCD
            seg7_show_mode1_decimal(strict_match, pct_hundredths);
            lcd_show_mode1_decimal_result(strict_match, pct_hundredths);

        } else if (choice == '2') {
            // ================================================================
            // MODE 2 — MOTIF DETECTION (Preserved completely unchanged)
            // ================================================================
            LED_REG = LED_WAIT_REF;
            uart_puts("Enter reference DNA sequence: ");
            int ref_len = read_dna_sequence(ref_seq, 128);

            LED_REG = LED_WAIT_QUERY;
            uart_puts("Enter motif sequence: ");
            int motif_len = read_dna_sequence(query_seq, 16);

            // Display accepted sequences on UART
            uart_puts("\nAccepted inputs:\n");
            uart_puts("Reference: ");
            uart_puts(ref_seq);
            uart_puts("\nMotif:     ");
            uart_puts(query_seq);
            uart_puts("\n\n");

            // Display inputs on LCD immediately with paging for long inputs
            lcd_display_input_sequences(2, ref_seq, ref_len, query_seq, motif_len);

            LED_REG = LED_PROCESSING;
            uart_puts("Processing...\n\n");

            // Execute hardware motif search on FPGA accelerator
            unsigned int match_count = 0;
            run_dna_accelerator(1, ref_seq, ref_len, query_seq, motif_len, &match_count);

            unsigned int recorded_positions[16];
            unsigned int num_recorded = (match_count > 16) ? 16 : match_count;

            LED_REG = LED_MOTIF_COMPLETE | (match_count & 0xFF);

            // Print complete count and all matching positions to PuTTY
            uart_puts("========================================\n");
            uart_puts("MODE 2 RESULT:\n");
            uart_puts("Reference: ");
            uart_puts(ref_seq);
            uart_puts("\nMotif:     ");
            uart_puts(query_seq);
            uart_puts("\nMatch count: ");
            uart_put_uint(match_count);
            uart_puts("\nMatch positions: ");
            if (match_count == 0) {
                uart_puts("None\n");
            } else {
                for (unsigned int i = 0; i < match_count; i++) {
                    DNA_POS_INDEX = i;
                    unsigned int pos = DNA_POS_DATA & 0xFF;
                    if (i < 16) recorded_positions[i] = pos;
                    uart_put_uint(pos);
                    if (i + 1 < match_count) {
                        uart_puts(", ");
                    }
                }
                uart_puts("\n");
            }
            uart_puts("========================================\n\n");

            // Update on-board seven-segment display and 16x2 I2C LCD
            seg7_show_mode2(match_count, recorded_positions, num_recorded);
            lcd_show_mode2_result(match_count, recorded_positions, num_recorded);
        }
    }

    return 0;
}
