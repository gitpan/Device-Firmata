#!/usr/bin/perl

use strict;
use lib '../lib';
use vars qw/ $PULSE_LEN $PIN_LOOKUP $CHARMAP /;
use Data::Dumper;
use Device::Firmata::Constants qw/ :all /;
use Device::Firmata::Protocol;
use Device::Firmata;

use constant ($PIN_LOOKUP={
    CS1  => 5,
    CS2  => 6,
    CS3  => 7,
    CS4  => 8,

    WR   => 2,
    RD   => 3,
    DATA => 4,

    FONT_PARSER_WAITING  => 0,
    FONT_PARSER_METADATA => 1,
    FONT_PARSER_BITMAP   => 2,
});

#$Device::Firmata::DEBUG = 1;
$PULSE_LEN = 0.001;

$|++;

my $device = Device::Firmata->open('/dev/ttyUSB0');

# Pin connection table

# cs1  - digital 5
# cs2  - digital 6
# cs3  - digital 7
# cs4  - digital 8
# osc  - ground
# sync - floating

# wr   - read/write toggle - digital 2
# rd   - clock read signal - digital 3
# data - 1 bit data.       - digital 4

# Create all the functions that we'll use to play with the pins
no strict 'refs';
while ( my ($name,$pin) = each %$PIN_LOOKUP ) {
    $device->pin_mode($pin=>,PIN_OUTPUT);
    my $lc_name = lc $name;
    my $lc_sub = *{"::".$lc_name} = sub { 
        print "$name is $_[0]\n";
        $device->digital_write($pin=>$_[0]);
        select undef, undef, undef, $PULSE_LEN;
    };
    *{"::".$lc_name."_pulse"} = sub { 
        print "Pulsing: $name\n";
        $device->digital_write($pin=>0);
        select undef, undef, undef, $PULSE_LEN;
        $device->digital_write($pin=>1);
        select undef, undef, undef, $PULSE_LEN;
    };
    *{"::".$lc_name."_pulse_inv"} = sub { 
        print "Pulsing: $name\n";
        $device->digital_write($pin=>1);
        select undef, undef, undef, $PULSE_LEN;
        $device->digital_write($pin=>0);
        select undef, undef, undef, $PULSE_LEN;
    };

}
use strict;

# Now let's initialize firmata
$device->probe;

# Set all pins high since that seems to be the default state
cs1(1);
wr(1);
rd(1);
data(1);

# Disable the unit
cs1(0);
preamble_send($device,"100");
data_send($device,"000000000");

# Turn on the LEDs
cs1_pulse_inv();
preamble_send($device,"100");
data_send($device,"000000111");

# Turn on system oscillator
cs1_pulse_inv();
preamble_send($device,"100");
data_send($device,"000000011");

# Commons option
cs1_pulse_inv();
preamble_send($device,"100");
data_send($device,"001010111");

# Init the matrix!
matrix_init($device);

while (1) {

    my @d = localtime;
    my $time_str = sprintf("%02i%02i%02i",@d[2,1,0]);
    matrix_printf($time_str);
    matrix_commit($device);
    select undef,undef,undef,0.1;

}


sub preamble_send {
# --------------------------------------------------
    my ( $device, $data ) = @_;
    my $buf = substr $data, 0, 3;
    for my $d (split //, $buf) {
        data($d);
        wr_pulse();
    }
}

sub data_send {
# --------------------------------------------------
    my ( $device, $data ) = @_;
    for my $d (split //, $data) {
        data($d);
        wr_pulse();
    }
}

sub data_send_int {
# --------------------------------------------------
    my ( $device, $v, $bits, $offset ) = @_;
    $bits ||= 8;
    if ( not defined $offset ) {
        $offset ||= 8-$bits;
    }
    my $data = substr unpack( "B*", pack "c", $v ), $offset, $bits;
    print "V <$v> BITS: $bits SENDING: $data\n";

    data_send($device,$data);
}

my @matrix_current = map {0} (1..32);
my @matrix_pending = map {0} (1..32);

sub matrix_init {
# --------------------------------------------------
    my ( $device ) = @_;

# Wipe the screen
    cs1_pulse_inv();
    preamble_send($device,"101");
    data_send($device,"0000000"); # address (MA)
    for (1..64) {
        data_send($device,"0000"); # data (MA)
    }

# Wipe the arrays
    @matrix_current = map {0} (1..32);
    @matrix_pending = map {0} (1..32);
}

sub matrix_write {
# --------------------------------------------------
    my ( $device, $address, $data ) = @_;

# 3 preamble bits 101
    preamble(qw( 1 0 1 ));

# Then the address, which is 7 bits
    for my $i ( 0..6 ) {
        data($address & 0x40);
        wr_pulse();
        $address <<= 1;
    }

# And then the 4 bits of data
    for my $i ( 0..3 ) {
        data($data & 0x01);
        wr_pulse();
        $address >>= 1;
    }
}

sub matrix_set_pixel {
# --------------------------------------------------
    my ( $x, $y, $on ) = @_;
    if ( $on ) {
        $matrix_pending[$x] |= 1<<$y;
    }
    else {
        $matrix_pending[$x] &= ~(1<<$y);
    }
}

sub matrix_get_pixel {
# --------------------------------------------------
    my ( $x, $y ) = @_;
    return ( $matrix_pending[$x] & (1<<$y) );
}

sub matrix_commit {
# --------------------------------------------------
# Only update the memory that requires refreshing
#
    my ( $device ) = @_;

    for my $i (0..31) {
        my $diff = $matrix_current[$i] ^ $matrix_pending[$i];
        my $v    = $matrix_current[$i] = $matrix_pending[$i];

# Low nybble
        if ( $diff & 0x0f ) {
        print "LOW $i: DIFF: $diff V: $v\n";

            cs1_pulse_inv();
            preamble_send($device,"101");
            data_send_int($device,$i*2+1,7); # address (MA)
            data_send_int($device,$v,4);
        }

# High nybble
        if ( $diff & 0xf0 ) {
        print "HIGH $i: DIFF: $diff V: $v\n";

            cs1_pulse_inv();
            preamble_send($device,"101");
            data_send_int($device,$i*2,7); # address (MA)
            data_send_int($device,$v,4,0);
        }
    }
}

sub matrix_dump {
# --------------------------------------------------
    for my $i ( 0..31 ) {
        printf "%02i: %s\n", $i, $matrix_pending[$i];
    }
}

sub matrix_clear {
# --------------------------------------------------
    for my $i (0..31) {
        $matrix_pending[$i] = 0;
    };
}

sub matrix_printf {
# --------------------------------------------------
# Printf's a string to the matrix. We don't do any 
# special indexing and start writing the information
# from 0,0
#
    my $format = shift;
    my $string = sprintf( $format, @_ );

# Let's clear the matrix to start with a blank canvas...
    matrix_clear();

# Now let's start punching the characters down...
    my @chararray = unpack "c*", $string;
    my $charmap = font_load();
    my $x = 0;
    for my $ch ( @chararray ) {
        if ( my $char = $charmap->{$ch} ) {
            my $bitmap = $char->{bitmap};
            for my $y ( 0..7 ) {
                my $row = unpack( "B*", pack "c", $bitmap->[$y] );
                my $xo  = 0;
                for my $on ( split //, $row ) {
                    $on and matrix_set_pixel($x+$xo,7-$y,1);
                    $xo++;
                }
            }
        }
        $x += 5; # 8 pixels per char!
    }

}

sub font_load {
# --------------------------------------------------
    $CHARMAP and return $CHARMAP;

    my $charmap = {};
    my $char;
    my $state = FONT_PARSER_WAITING;
    while ( my $l = <DATA> ) {STATES:{
        $l =~ s/\n//g;
        $l =~ /^\s*$/ and last;
        $_ = $l;

        $state == FONT_PARSER_WAITING and do {
            /^STARTCHAR\s+(.*)/ and do {
                $state = FONT_PARSER_METADATA;
                $char = {
                    name => $+
                };
                last;
            };
        };

        $state == FONT_PARSER_METADATA and do {
            /^BITMAP/ and do {
                $state = FONT_PARSER_BITMAP;
                last;
            };

            /^ENCODING\s+(\d+)/ and do {
                $char->{char} = $+;
                last;
            };

        };

        $state == FONT_PARSER_BITMAP and do {
            /^ENDCHAR/ and do {
                $state = FONT_PARSER_WAITING;
                $charmap->{$char->{char}} = $char;
                last;
            };
            my $v = hex($l);
            push @{$char->{bitmap}}, $v;
        };

    }}

# This just prints debugging information
    if ( 1 ) {
        my @sorted_names = sort { $a <=> $b } keys %$charmap;

        for my $n ( @sorted_names ) {
            my $c = $charmap->{$n};
            print "\n---[ #$n - $c->{name} ]----\n";
            my $d = $c->{bitmap};
            for my $r ( @$d ) {
                my $b = unpack "B*", chr $r;
                $b =~ tr/01/ #/;
                print $b."\n";
            }
        }
    }

    return $CHARMAP = $charmap;
};


__DATA__
STARTFONT 2.1
COMMENT "$ucs-fonts: 5x7.bdf,v 1.37 2002-11-10 19:12:30+00 mgk25 Rel $"
COMMENT "Send bug reports to Markus Kuhn <http://www.cl.cam.ac.uk/~mgk25/>"
FONT -Misc-Fixed-Medium-R-Normal--7-70-75-75-C-50-ISO10646-1
SIZE 7 75 75
FONTBOUNDINGBOX 5 7 0 -1
STARTPROPERTIES 23
FONTNAME_REGISTRY ""
FOUNDRY "Misc"
FAMILY_NAME "Fixed"
WEIGHT_NAME "Medium"
SLANT "R"
SETWIDTH_NAME "Normal"
ADD_STYLE_NAME ""
PIXEL_SIZE 7
POINT_SIZE 70
RESOLUTION_X 75
RESOLUTION_Y 75
SPACING "C"
AVERAGE_WIDTH 50
CHARSET_REGISTRY "ISO10646"
CHARSET_ENCODING "1"
FONT_ASCENT 6
FONT_DESCENT 1
DESTINATION 1
DEFAULT_CHAR 0
COPYRIGHT "Public domain font.  Share and enjoy."
_XMBDFED_INFO "Edited with xmbdfed 4.5."
CAP_HEIGHT 6
X_HEIGHT 4
ENDPROPERTIES
CHARS 1848
STARTCHAR char0
ENCODING 0
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
A8
00
88
00
A8
00
ENDCHAR
STARTCHAR space
ENCODING 32
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
00
00
00
ENDCHAR
STARTCHAR exclam
ENCODING 33
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
20
20
00
20
00
ENDCHAR
STARTCHAR quotedbl
ENCODING 34
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
50
00
00
00
00
ENDCHAR
STARTCHAR numbersign
ENCODING 35
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
50
F8
50
F8
50
00
ENDCHAR
STARTCHAR dollar
ENCODING 36
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
70
A0
70
28
70
00
ENDCHAR
STARTCHAR percent
ENCODING 37
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
90
20
40
90
10
00
ENDCHAR
STARTCHAR ampersand
ENCODING 38
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
40
A0
40
A0
50
00
ENDCHAR
STARTCHAR quotesingle
ENCODING 39
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
20
00
00
00
00
ENDCHAR
STARTCHAR parenleft
ENCODING 40
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
40
40
40
20
00
ENDCHAR
STARTCHAR parenright
ENCODING 41
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
20
20
20
20
40
00
ENDCHAR
STARTCHAR asterisk
ENCODING 42
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
50
20
70
20
50
00
ENDCHAR
STARTCHAR plus
ENCODING 43
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
20
20
F8
20
20
00
ENDCHAR
STARTCHAR comma
ENCODING 44
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
30
20
40
ENDCHAR
STARTCHAR hyphen
ENCODING 45
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
F0
00
00
00
ENDCHAR
STARTCHAR period
ENCODING 46
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
60
60
00
ENDCHAR
STARTCHAR slash
ENCODING 47
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
10
20
40
80
00
00
ENDCHAR
STARTCHAR zero
ENCODING 48
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
50
50
50
50
20
00
ENDCHAR
STARTCHAR one
ENCODING 49
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
60
20
20
20
70
00
ENDCHAR
STARTCHAR two
ENCODING 50
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
10
20
40
F0
00
ENDCHAR
STARTCHAR three
ENCODING 51
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
10
60
10
90
60
00
ENDCHAR
STARTCHAR four
ENCODING 52
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
60
A0
F0
20
20
00
ENDCHAR
STARTCHAR five
ENCODING 53
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
80
E0
10
90
60
00
ENDCHAR
STARTCHAR six
ENCODING 54
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
80
E0
90
90
60
00
ENDCHAR
STARTCHAR seven
ENCODING 55
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
10
20
20
40
40
00
ENDCHAR
STARTCHAR eight
ENCODING 56
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
60
90
90
60
00
ENDCHAR
STARTCHAR nine
ENCODING 57
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
70
10
60
00
ENDCHAR
STARTCHAR colon
ENCODING 58
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
60
60
00
60
60
00
ENDCHAR
STARTCHAR semicolon
ENCODING 59
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
60
60
00
60
40
80
ENDCHAR
STARTCHAR less
ENCODING 60
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
10
20
40
20
10
00
ENDCHAR
STARTCHAR equal
ENCODING 61
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F0
00
F0
00
00
ENDCHAR
STARTCHAR greater
ENCODING 62
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
40
20
10
20
40
00
ENDCHAR
STARTCHAR question
ENCODING 63
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
50
10
20
00
20
00
ENDCHAR
STARTCHAR at
ENCODING 64
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
B0
B0
80
60
00
ENDCHAR
STARTCHAR A
ENCODING 65
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
F0
90
90
00
ENDCHAR
STARTCHAR B
ENCODING 66
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
E0
90
90
E0
00
ENDCHAR
STARTCHAR C
ENCODING 67
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
80
80
90
60
00
ENDCHAR
STARTCHAR D
ENCODING 68
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
90
90
90
E0
00
ENDCHAR
STARTCHAR E
ENCODING 69
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
80
E0
80
80
F0
00
ENDCHAR
STARTCHAR F
ENCODING 70
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
80
E0
80
80
80
00
ENDCHAR
STARTCHAR G
ENCODING 71
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
80
B0
90
70
00
ENDCHAR
STARTCHAR H
ENCODING 72
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
F0
90
90
90
00
ENDCHAR
STARTCHAR I
ENCODING 73
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
20
20
20
70
00
ENDCHAR
STARTCHAR J
ENCODING 74
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
10
10
10
90
60
00
ENDCHAR
STARTCHAR K
ENCODING 75
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
A0
C0
C0
A0
90
00
ENDCHAR
STARTCHAR L
ENCODING 76
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
80
80
80
80
F0
00
ENDCHAR
STARTCHAR M
ENCODING 77
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
F0
F0
90
90
90
00
ENDCHAR
STARTCHAR N
ENCODING 78
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
D0
D0
B0
B0
90
00
ENDCHAR
STARTCHAR O
ENCODING 79
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
90
90
60
00
ENDCHAR
STARTCHAR P
ENCODING 80
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
90
E0
80
80
00
ENDCHAR
STARTCHAR Q
ENCODING 81
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
90
D0
60
10
ENDCHAR
STARTCHAR R
ENCODING 82
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
90
E0
A0
90
00
ENDCHAR
STARTCHAR S
ENCODING 83
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
40
20
90
60
00
ENDCHAR
STARTCHAR T
ENCODING 84
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
20
20
20
20
00
ENDCHAR
STARTCHAR U
ENCODING 85
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
90
90
90
60
00
ENDCHAR
STARTCHAR V
ENCODING 86
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
90
90
60
60
00
ENDCHAR
STARTCHAR W
ENCODING 87
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
90
F0
F0
90
00
ENDCHAR
STARTCHAR X
ENCODING 88
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
60
60
90
90
00
ENDCHAR
STARTCHAR Y
ENCODING 89
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
50
20
20
20
00
ENDCHAR
STARTCHAR Z
ENCODING 90
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
10
20
40
80
F0
00
ENDCHAR
STARTCHAR bracketleft
ENCODING 91
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
40
40
40
40
70
00
ENDCHAR
STARTCHAR backslash
ENCODING 92
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
80
40
20
10
00
00
ENDCHAR
STARTCHAR bracketright
ENCODING 93
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
10
10
10
10
70
00
ENDCHAR
STARTCHAR asciicircum
ENCODING 94
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
50
00
00
00
00
00
ENDCHAR
STARTCHAR underscore
ENCODING 95
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
00
F0
00
ENDCHAR
STARTCHAR grave
ENCODING 96
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
20
00
00
00
00
00
ENDCHAR
STARTCHAR a
ENCODING 97
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
90
B0
50
00
ENDCHAR
STARTCHAR b
ENCODING 98
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
80
E0
90
90
E0
00
ENDCHAR
STARTCHAR c
ENCODING 99
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
80
80
60
00
ENDCHAR
STARTCHAR d
ENCODING 100
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
10
70
90
90
70
00
ENDCHAR
STARTCHAR e
ENCODING 101
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
B0
C0
60
00
ENDCHAR
STARTCHAR f
ENCODING 102
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
50
40
E0
40
40
00
ENDCHAR
STARTCHAR g
ENCODING 103
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
90
60
80
70
ENDCHAR
STARTCHAR h
ENCODING 104
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
80
E0
90
90
90
00
ENDCHAR
STARTCHAR i
ENCODING 105
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
00
60
20
20
70
00
ENDCHAR
STARTCHAR j
ENCODING 106
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
10
10
10
50
20
ENDCHAR
STARTCHAR k
ENCODING 107
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
80
A0
C0
A0
90
00
ENDCHAR
STARTCHAR l
ENCODING 108
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
20
20
20
20
70
00
ENDCHAR
STARTCHAR m
ENCODING 109
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
A0
F0
90
90
00
ENDCHAR
STARTCHAR n
ENCODING 110
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
E0
90
90
90
00
ENDCHAR
STARTCHAR o
ENCODING 111
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
90
90
60
00
ENDCHAR
STARTCHAR p
ENCODING 112
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
E0
90
90
E0
80
ENDCHAR
STARTCHAR q
ENCODING 113
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
90
90
70
10
ENDCHAR
STARTCHAR r
ENCODING 114
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
E0
90
80
80
00
ENDCHAR
STARTCHAR s
ENCODING 115
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
C0
30
E0
00
ENDCHAR
STARTCHAR t
ENCODING 116
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
40
E0
40
40
30
00
ENDCHAR
STARTCHAR u
ENCODING 117
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
90
90
70
00
ENDCHAR
STARTCHAR v
ENCODING 118
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
50
50
20
00
ENDCHAR
STARTCHAR w
ENCODING 119
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
90
F0
F0
00
ENDCHAR
STARTCHAR x
ENCODING 120
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
60
60
90
00
ENDCHAR
STARTCHAR y
ENCODING 121
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
90
50
20
40
ENDCHAR
STARTCHAR z
ENCODING 122
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F0
20
40
F0
00
ENDCHAR
STARTCHAR braceleft
ENCODING 123
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
20
60
20
20
10
00
ENDCHAR
STARTCHAR bar
ENCODING 124
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
20
20
20
20
00
ENDCHAR
STARTCHAR braceright
ENCODING 125
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
20
30
20
20
40
00
ENDCHAR
STARTCHAR asciitilde
ENCODING 126
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
A0
00
00
00
00
00
ENDCHAR
STARTCHAR space
ENCODING 160
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
00
00
00
ENDCHAR
STARTCHAR exclamdown
ENCODING 161
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
00
20
20
20
20
00
ENDCHAR
STARTCHAR cent
ENCODING 162
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
20
70
A0
A0
70
20
ENDCHAR
STARTCHAR sterling
ENCODING 163
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
30
40
E0
40
B0
00
ENDCHAR
STARTCHAR currency
ENCODING 164
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
88
70
50
70
88
00
ENDCHAR
STARTCHAR yen
ENCODING 165
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
20
70
20
20
00
ENDCHAR
STARTCHAR brokenbar
ENCODING 166
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
20
20
00
20
20
00
ENDCHAR
STARTCHAR section
ENCODING 167
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
40
60
50
30
10
60
ENDCHAR
STARTCHAR dieresis
ENCODING 168
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
00
00
00
00
00
ENDCHAR
STARTCHAR copyright
ENCODING 169
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
88
A8
C8
A8
88
70
ENDCHAR
STARTCHAR ordfeminine
ENCODING 170
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
A0
60
00
00
00
00
ENDCHAR
STARTCHAR guillemotleft
ENCODING 171
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
48
90
48
00
00
ENDCHAR
STARTCHAR logicalnot
ENCODING 172
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
F0
10
00
00
ENDCHAR
STARTCHAR hyphen
ENCODING 173
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
70
00
00
00
ENDCHAR
STARTCHAR registered
ENCODING 174
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
88
E8
C8
C8
88
70
ENDCHAR
STARTCHAR macron
ENCODING 175
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
00
00
00
00
00
00
ENDCHAR
STARTCHAR degree
ENCODING 176
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
50
20
00
00
00
00
ENDCHAR
STARTCHAR plusminus
ENCODING 177
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
F8
20
20
F8
00
ENDCHAR
STARTCHAR twosuperior
ENCODING 178
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
20
40
60
00
00
00
ENDCHAR
STARTCHAR threesuperior
ENCODING 179
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
60
20
60
00
00
00
ENDCHAR
STARTCHAR acute
ENCODING 180
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
00
00
00
00
00
ENDCHAR
STARTCHAR mu
ENCODING 181
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
90
90
E0
80
ENDCHAR
STARTCHAR paragraph
ENCODING 182
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
D0
D0
50
50
50
00
ENDCHAR
STARTCHAR periodcentered
ENCODING 183
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
60
00
00
00
ENDCHAR
STARTCHAR cedilla
ENCODING 184
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
00
20
40
ENDCHAR
STARTCHAR onesuperior
ENCODING 185
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
60
20
70
00
00
00
ENDCHAR
STARTCHAR ordmasculine
ENCODING 186
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
A0
40
00
00
00
00
ENDCHAR
STARTCHAR guillemotright
ENCODING 187
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
48
90
00
00
ENDCHAR
STARTCHAR onequarter
ENCODING 188
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
80
80
90
30
70
10
ENDCHAR
STARTCHAR onehalf
ENCODING 189
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
80
80
B0
10
20
30
ENDCHAR
STARTCHAR threequarters
ENCODING 190
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
C0
C0
40
D0
30
70
10
ENDCHAR
STARTCHAR questiondown
ENCODING 191
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
00
20
40
50
20
00
ENDCHAR
STARTCHAR Agrave
ENCODING 192
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
F0
90
90
00
ENDCHAR
STARTCHAR Aacute
ENCODING 193
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
F0
90
90
00
ENDCHAR
STARTCHAR Acircumflex
ENCODING 194
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
F0
90
90
00
ENDCHAR
STARTCHAR Atilde
ENCODING 195
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
F0
90
90
00
ENDCHAR
STARTCHAR Adieresis
ENCODING 196
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
60
90
F0
90
90
00
ENDCHAR
STARTCHAR Aring
ENCODING 197
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
60
90
F0
90
90
00
ENDCHAR
STARTCHAR AE
ENCODING 198
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
A0
B0
E0
A0
B0
00
ENDCHAR
STARTCHAR Ccedilla
ENCODING 199
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
80
80
90
60
40
ENDCHAR
STARTCHAR Egrave
ENCODING 200
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
80
E0
80
80
F0
00
ENDCHAR
STARTCHAR Eacute
ENCODING 201
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
80
E0
80
80
F0
00
ENDCHAR
STARTCHAR Ecircumflex
ENCODING 202
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
80
E0
80
80
F0
00
ENDCHAR
STARTCHAR Edieresis
ENCODING 203
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
80
E0
80
80
F0
00
ENDCHAR
STARTCHAR Igrave
ENCODING 204
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
20
20
20
70
00
ENDCHAR
STARTCHAR Iacute
ENCODING 205
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
20
20
20
70
00
ENDCHAR
STARTCHAR Icircumflex
ENCODING 206
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
20
20
20
70
00
ENDCHAR
STARTCHAR Idieresis
ENCODING 207
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
20
20
20
70
00
ENDCHAR
STARTCHAR Eth
ENCODING 208
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
50
D0
50
50
E0
00
ENDCHAR
STARTCHAR Ntilde
ENCODING 209
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
B0
90
D0
B0
B0
90
00
ENDCHAR
STARTCHAR Ograve
ENCODING 210
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
90
90
60
00
ENDCHAR
STARTCHAR Oacute
ENCODING 211
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
90
90
60
00
ENDCHAR
STARTCHAR Ocircumflex
ENCODING 212
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
90
90
60
00
ENDCHAR
STARTCHAR Otilde
ENCODING 213
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
90
90
60
00
ENDCHAR
STARTCHAR Odieresis
ENCODING 214
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
60
90
90
90
60
00
ENDCHAR
STARTCHAR multiply
ENCODING 215
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
60
60
90
00
ENDCHAR
STARTCHAR Oslash
ENCODING 216
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
B0
B0
D0
D0
E0
00
ENDCHAR
STARTCHAR Ugrave
ENCODING 217
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
90
90
90
60
00
ENDCHAR
STARTCHAR Uacute
ENCODING 218
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
90
90
90
60
00
ENDCHAR
STARTCHAR Ucircumflex
ENCODING 219
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
90
90
90
60
00
ENDCHAR
STARTCHAR Udieresis
ENCODING 220
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
00
90
90
90
60
00
ENDCHAR
STARTCHAR Yacute
ENCODING 221
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
50
20
20
20
00
ENDCHAR
STARTCHAR Thorn
ENCODING 222
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
E0
90
E0
80
80
00
ENDCHAR
STARTCHAR germandbls
ENCODING 223
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
A0
90
90
A0
00
ENDCHAR
STARTCHAR agrave
ENCODING 224
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
20
70
90
B0
50
00
ENDCHAR
STARTCHAR aacute
ENCODING 225
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
70
90
B0
50
00
ENDCHAR
STARTCHAR acircumflex
ENCODING 226
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
50
70
90
B0
50
00
ENDCHAR
STARTCHAR atilde
ENCODING 227
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
A0
70
90
B0
50
00
ENDCHAR
STARTCHAR adieresis
ENCODING 228
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
70
90
B0
50
00
ENDCHAR
STARTCHAR aring
ENCODING 229
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
60
70
90
B0
50
00
ENDCHAR
STARTCHAR ae
ENCODING 230
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
B0
A0
70
00
ENDCHAR
STARTCHAR ccedilla
ENCODING 231
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
30
40
40
30
20
ENDCHAR
STARTCHAR egrave
ENCODING 232
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
20
60
B0
C0
60
00
ENDCHAR
STARTCHAR eacute
ENCODING 233
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
60
B0
C0
60
00
ENDCHAR
STARTCHAR ecircumflex
ENCODING 234
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
A0
60
B0
C0
60
00
ENDCHAR
STARTCHAR edieresis
ENCODING 235
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
00
60
B0
C0
60
00
ENDCHAR
STARTCHAR igrave
ENCODING 236
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
20
60
20
20
70
00
ENDCHAR
STARTCHAR iacute
ENCODING 237
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
60
20
20
70
00
ENDCHAR
STARTCHAR icircumflex
ENCODING 238
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
50
60
20
20
70
00
ENDCHAR
STARTCHAR idieresis
ENCODING 239
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
60
20
20
70
00
ENDCHAR
STARTCHAR eth
ENCODING 240
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
30
60
90
90
60
00
ENDCHAR
STARTCHAR ntilde
ENCODING 241
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
A0
E0
90
90
90
00
ENDCHAR
STARTCHAR ograve
ENCODING 242
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
20
60
90
90
60
00
ENDCHAR
STARTCHAR oacute
ENCODING 243
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
60
90
90
60
00
ENDCHAR
STARTCHAR ocircumflex
ENCODING 244
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
00
60
90
90
60
00
ENDCHAR
STARTCHAR otilde
ENCODING 245
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
A0
60
90
90
60
00
ENDCHAR
STARTCHAR odieresis
ENCODING 246
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
60
90
90
60
00
ENDCHAR
STARTCHAR divide
ENCODING 247
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
60
00
F0
00
60
00
ENDCHAR
STARTCHAR oslash
ENCODING 248
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
B0
D0
E0
00
ENDCHAR
STARTCHAR ugrave
ENCODING 249
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
20
90
90
90
70
00
ENDCHAR
STARTCHAR uacute
ENCODING 250
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
90
90
90
70
00
ENDCHAR
STARTCHAR ucircumflex
ENCODING 251
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
00
90
90
90
70
00
ENDCHAR
STARTCHAR udieresis
ENCODING 252
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
90
90
90
70
00
ENDCHAR
STARTCHAR yacute
ENCODING 253
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
90
90
50
20
40
ENDCHAR
STARTCHAR thorn
ENCODING 254
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
80
E0
90
90
E0
80
ENDCHAR
STARTCHAR ydieresis
ENCODING 255
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
90
90
50
20
40
ENDCHAR
STARTCHAR Amacron
ENCODING 256
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
F0
90
90
00
ENDCHAR
STARTCHAR amacron
ENCODING 257
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
00
70
90
B0
50
00
ENDCHAR
STARTCHAR Abreve
ENCODING 258
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
F0
90
90
00
ENDCHAR
STARTCHAR abreve
ENCODING 259
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
60
70
90
B0
50
00
ENDCHAR
STARTCHAR Aogonek
ENCODING 260
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
F0
90
90
10
ENDCHAR
STARTCHAR aogonek
ENCODING 261
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
90
B0
50
08
ENDCHAR
STARTCHAR Cacute
ENCODING 262
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
80
80
90
60
00
ENDCHAR
STARTCHAR cacute
ENCODING 263
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
20
30
40
40
30
00
ENDCHAR
STARTCHAR Ccircumflex
ENCODING 264
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
80
80
90
60
00
ENDCHAR
STARTCHAR ccircumflex
ENCODING 265
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
00
60
80
80
60
00
ENDCHAR
STARTCHAR Cdotaccent
ENCODING 266
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
80
80
90
60
00
ENDCHAR
STARTCHAR cdotaccent
ENCODING 267
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
60
80
80
60
00
ENDCHAR
STARTCHAR Ccaron
ENCODING 268
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
80
80
90
60
00
ENDCHAR
STARTCHAR ccaron
ENCODING 269
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
40
60
80
80
60
00
ENDCHAR
STARTCHAR Dcaron
ENCODING 270
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
90
90
90
E0
00
ENDCHAR
STARTCHAR dcaron
ENCODING 271
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
50
10
70
90
70
00
ENDCHAR
STARTCHAR Dcroat
ENCODING 272
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
D0
90
90
E0
00
ENDCHAR
STARTCHAR dcroat
ENCODING 273
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
38
10
70
90
70
00
ENDCHAR
STARTCHAR Emacron
ENCODING 274
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
80
E0
80
80
F0
00
ENDCHAR
STARTCHAR emacron
ENCODING 275
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
00
60
B0
C0
60
00
ENDCHAR
STARTCHAR Ebreve
ENCODING 276
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
80
E0
80
80
F0
00
ENDCHAR
STARTCHAR ebreve
ENCODING 277
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
60
60
B0
C0
60
00
ENDCHAR
STARTCHAR Edotaccent
ENCODING 278
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
80
E0
80
80
F0
00
ENDCHAR
STARTCHAR edotaccent
ENCODING 279
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
60
B0
C0
60
00
ENDCHAR
STARTCHAR Eogonek
ENCODING 280
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
80
E0
80
80
F0
40
ENDCHAR
STARTCHAR eogonek
ENCODING 281
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
B0
C0
60
40
ENDCHAR
STARTCHAR Ecaron
ENCODING 282
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
80
E0
80
80
F0
00
ENDCHAR
STARTCHAR ecaron
ENCODING 283
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
40
60
B0
C0
60
00
ENDCHAR
STARTCHAR Gcircumflex
ENCODING 284
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
80
B0
90
70
00
ENDCHAR
STARTCHAR gcircumflex
ENCODING 285
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
00
70
90
60
80
70
ENDCHAR
STARTCHAR Gbreve
ENCODING 286
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
80
B0
90
70
00
ENDCHAR
STARTCHAR gbreve
ENCODING 287
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
20
70
90
60
80
70
ENDCHAR
STARTCHAR Gdotaccent
ENCODING 288
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
80
B0
90
70
00
ENDCHAR
STARTCHAR gdotaccent
ENCODING 289
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
00
70
90
60
80
70
ENDCHAR
STARTCHAR Gcommaaccent
ENCODING 290
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
80
B0
90
70
40
ENDCHAR
STARTCHAR gcommaaccent
ENCODING 291
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
20
70
90
60
80
70
ENDCHAR
STARTCHAR Hcircumflex
ENCODING 292
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
F0
90
90
90
00
ENDCHAR
STARTCHAR hcircumflex
ENCODING 293
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
A0
80
E0
90
90
00
ENDCHAR
STARTCHAR Hbar
ENCODING 294
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
F8
90
F0
90
90
00
ENDCHAR
STARTCHAR hbar
ENCODING 295
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
C0
80
E0
90
90
00
ENDCHAR
STARTCHAR Itilde
ENCODING 296
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
20
20
20
70
00
ENDCHAR
STARTCHAR itilde
ENCODING 297
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
A0
60
20
20
70
00
ENDCHAR
STARTCHAR Imacron
ENCODING 298
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
20
20
20
70
00
ENDCHAR
STARTCHAR imacron
ENCODING 299
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
00
60
20
20
70
00
ENDCHAR
STARTCHAR Ibreve
ENCODING 300
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
20
20
20
70
00
ENDCHAR
STARTCHAR ibreve
ENCODING 301
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
60
60
20
20
70
00
ENDCHAR
STARTCHAR Iogonek
ENCODING 302
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
20
20
20
70
40
ENDCHAR
STARTCHAR iogonek
ENCODING 303
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
00
60
20
20
70
40
ENDCHAR
STARTCHAR Idotaccent
ENCODING 304
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
20
20
20
70
00
ENDCHAR
STARTCHAR dotlessi
ENCODING 305
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
20
20
70
00
ENDCHAR
STARTCHAR IJ
ENCODING 306
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
90
90
D0
A0
00
ENDCHAR
STARTCHAR ij
ENCODING 307
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
00
90
90
90
D0
20
ENDCHAR
STARTCHAR Jcircumflex
ENCODING 308
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
10
10
10
90
60
00
ENDCHAR
STARTCHAR jcircumflex
ENCODING 309
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
50
00
20
20
A0
40
ENDCHAR
STARTCHAR Kcommaaccent
ENCODING 310
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
A0
C0
C0
A0
90
80
ENDCHAR
STARTCHAR kcommaaccent
ENCODING 311
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
80
A0
C0
A0
90
80
ENDCHAR
STARTCHAR kgreenlandic
ENCODING 312
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
E0
90
90
00
ENDCHAR
STARTCHAR Lacute
ENCODING 313
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
A0
80
80
80
F0
00
ENDCHAR
STARTCHAR lacute
ENCODING 314
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
C8
50
40
40
40
E0
00
ENDCHAR
STARTCHAR Lcommaaccent
ENCODING 315
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
80
80
80
80
F0
80
ENDCHAR
STARTCHAR lcommaaccent
ENCODING 316
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
20
20
20
20
70
40
ENDCHAR
STARTCHAR Lcaron
ENCODING 317
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A8
90
80
80
80
F0
00
ENDCHAR
STARTCHAR lcaron
ENCODING 318
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A8
90
80
80
80
40
00
ENDCHAR
STARTCHAR Ldot
ENCODING 319
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
80
A0
80
80
F0
00
ENDCHAR
STARTCHAR ldot
ENCODING 320
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
C0
40
50
40
40
E0
00
ENDCHAR
STARTCHAR Lslash
ENCODING 321
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
80
C0
80
80
F0
00
ENDCHAR
STARTCHAR lslash
ENCODING 322
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
20
30
60
20
70
00
ENDCHAR
STARTCHAR Nacute
ENCODING 323
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
D0
D0
B0
B0
90
00
ENDCHAR
STARTCHAR nacute
ENCODING 324
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
E0
90
90
90
00
ENDCHAR
STARTCHAR Ncommaaccent
ENCODING 325
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
D0
D0
B0
B0
90
80
ENDCHAR
STARTCHAR ncommaaccent
ENCODING 326
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
E0
90
90
90
80
ENDCHAR
STARTCHAR Ncaron
ENCODING 327
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
D0
D0
B0
B0
90
00
ENDCHAR
STARTCHAR ncaron
ENCODING 328
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
40
E0
90
90
90
00
ENDCHAR
STARTCHAR napostrophe
ENCODING 329
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
00
E0
90
90
90
00
ENDCHAR
STARTCHAR Eng
ENCODING 330
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
D0
D0
B0
B0
90
20
ENDCHAR
STARTCHAR eng
ENCODING 331
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
E0
90
90
90
20
ENDCHAR
STARTCHAR Omacron
ENCODING 332
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
90
90
60
00
ENDCHAR
STARTCHAR omacron
ENCODING 333
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
00
60
90
90
60
00
ENDCHAR
STARTCHAR Obreve
ENCODING 334
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
90
90
60
00
ENDCHAR
STARTCHAR obreve
ENCODING 335
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
60
60
90
90
60
00
ENDCHAR
STARTCHAR Ohungarumlaut
ENCODING 336
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
90
90
60
00
ENDCHAR
STARTCHAR ohungarumlaut
ENCODING 337
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
48
90
60
90
90
60
00
ENDCHAR
STARTCHAR OE
ENCODING 338
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
A0
B0
A0
A0
70
00
ENDCHAR
STARTCHAR oe
ENCODING 339
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
B0
A0
70
00
ENDCHAR
STARTCHAR Racute
ENCODING 340
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
90
E0
A0
90
00
ENDCHAR
STARTCHAR racute
ENCODING 341
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
E0
90
80
80
00
ENDCHAR
STARTCHAR Rcommaaccent
ENCODING 342
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
90
E0
A0
90
80
ENDCHAR
STARTCHAR rcommaaccent
ENCODING 343
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
E0
90
80
80
40
ENDCHAR
STARTCHAR Rcaron
ENCODING 344
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
90
E0
A0
90
00
ENDCHAR
STARTCHAR rcaron
ENCODING 345
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
40
E0
90
80
80
00
ENDCHAR
STARTCHAR Sacute
ENCODING 346
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
40
20
90
60
00
ENDCHAR
STARTCHAR sacute
ENCODING 347
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
70
C0
30
E0
00
ENDCHAR
STARTCHAR Scircumflex
ENCODING 348
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
40
20
90
60
00
ENDCHAR
STARTCHAR scircumflex
ENCODING 349
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
00
70
C0
30
E0
00
ENDCHAR
STARTCHAR Scedilla
ENCODING 350
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
40
20
90
60
40
ENDCHAR
STARTCHAR scedilla
ENCODING 351
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
C0
30
E0
40
ENDCHAR
STARTCHAR Scaron
ENCODING 352
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
40
20
90
60
00
ENDCHAR
STARTCHAR scaron
ENCODING 353
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
20
70
C0
30
E0
00
ENDCHAR
STARTCHAR Tcommaaccent
ENCODING 354
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
20
20
20
20
40
ENDCHAR
STARTCHAR tcommaaccent
ENCODING 355
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
40
E0
40
40
30
40
ENDCHAR
STARTCHAR Tcaron
ENCODING 356
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
40
40
40
40
40
00
ENDCHAR
STARTCHAR tcaron
ENCODING 357
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
20
40
E0
40
30
00
ENDCHAR
STARTCHAR Tbar
ENCODING 358
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
40
E0
40
40
40
00
ENDCHAR
STARTCHAR tbar
ENCODING 359
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
E0
40
E0
40
30
00
ENDCHAR
STARTCHAR Utilde
ENCODING 360
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
90
90
90
60
00
ENDCHAR
STARTCHAR utilde
ENCODING 361
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
A0
90
90
90
70
00
ENDCHAR
STARTCHAR Umacron
ENCODING 362
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
90
90
90
60
00
ENDCHAR
STARTCHAR umacron
ENCODING 363
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
00
90
90
90
70
00
ENDCHAR
STARTCHAR Ubreve
ENCODING 364
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
90
90
90
60
00
ENDCHAR
STARTCHAR ubreve
ENCODING 365
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
60
00
90
90
70
00
ENDCHAR
STARTCHAR Uring
ENCODING 366
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
90
90
90
60
00
ENDCHAR
STARTCHAR uring
ENCODING 367
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
60
00
90
90
70
00
ENDCHAR
STARTCHAR Uhungarumlaut
ENCODING 368
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
90
90
90
60
00
ENDCHAR
STARTCHAR uhungarumlaut
ENCODING 369
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
48
90
00
90
90
70
00
ENDCHAR
STARTCHAR Uogonek
ENCODING 370
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
90
90
90
60
40
ENDCHAR
STARTCHAR uogonek
ENCODING 371
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
90
90
70
20
ENDCHAR
STARTCHAR Wcircumflex
ENCODING 372
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
90
F0
F0
90
00
ENDCHAR
STARTCHAR wcircumflex
ENCODING 373
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
50
00
90
F0
F0
00
ENDCHAR
STARTCHAR Ycircumflex
ENCODING 374
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
A0
A0
40
40
40
00
ENDCHAR
STARTCHAR ycircumflex
ENCODING 375
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
50
00
90
50
20
40
ENDCHAR
STARTCHAR Ydieresis
ENCODING 376
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
A0
A0
40
40
40
00
ENDCHAR
STARTCHAR Zacute
ENCODING 377
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
10
20
40
80
F0
00
ENDCHAR
STARTCHAR zacute
ENCODING 378
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
F0
20
40
F0
00
ENDCHAR
STARTCHAR Zdotaccent
ENCODING 379
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
10
20
40
80
F0
00
ENDCHAR
STARTCHAR zdotaccent
ENCODING 380
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
00
F0
20
40
F0
00
ENDCHAR
STARTCHAR Zcaron
ENCODING 381
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
10
20
40
80
F0
00
ENDCHAR
STARTCHAR zcaron
ENCODING 382
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
20
F0
20
40
F0
00
ENDCHAR
STARTCHAR longs
ENCODING 383
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
20
60
20
20
20
00
ENDCHAR
STARTCHAR uni0180
ENCODING 384
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
E0
40
60
50
60
00
ENDCHAR
STARTCHAR uni0181
ENCODING 385
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
50
60
50
50
60
00
ENDCHAR
STARTCHAR uni0182
ENCODING 386
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
80
E0
90
90
E0
00
ENDCHAR
STARTCHAR uni0183
ENCODING 387
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
40
60
50
50
60
00
ENDCHAR
STARTCHAR uni0184
ENCODING 388
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
C0
F0
48
48
70
00
ENDCHAR
STARTCHAR uni0185
ENCODING 389
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
C0
60
50
50
60
00
ENDCHAR
STARTCHAR uni0186
ENCODING 390
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
10
10
90
60
00
ENDCHAR
STARTCHAR uni0187
ENCODING 391
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
68
90
80
80
90
60
00
ENDCHAR
STARTCHAR uni0188
ENCODING 392
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
10
60
80
80
60
00
ENDCHAR
STARTCHAR uni0189
ENCODING 393
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
50
D0
50
50
E0
00
ENDCHAR
STARTCHAR uni018A
ENCODING 394
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
50
50
50
50
60
00
ENDCHAR
STARTCHAR uni018B
ENCODING 395
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
10
70
90
90
70
00
ENDCHAR
STARTCHAR uni018C
ENCODING 396
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
10
30
50
50
30
00
ENDCHAR
STARTCHAR uni018D
ENCODING 397
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
90
60
10
60
ENDCHAR
STARTCHAR uni018E
ENCODING 398
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
10
70
10
10
F0
00
ENDCHAR
STARTCHAR uni018F
ENCODING 399
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
10
F0
90
60
00
ENDCHAR
STARTCHAR uni0190
ENCODING 400
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
40
80
90
60
00
ENDCHAR
STARTCHAR uni0191
ENCODING 401
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
40
60
40
40
40
80
ENDCHAR
STARTCHAR florin
ENCODING 402
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
50
40
E0
40
40
80
ENDCHAR
STARTCHAR uni0193
ENCODING 403
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
90
80
B0
90
70
00
ENDCHAR
STARTCHAR uni0194
ENCODING 404
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
90
90
60
90
60
00
ENDCHAR
STARTCHAR uni0195
ENCODING 405
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
80
C8
A8
A8
90
00
ENDCHAR
STARTCHAR uni0196
ENCODING 406
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
20
20
20
20
10
00
ENDCHAR
STARTCHAR uni0197
ENCODING 407
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
70
20
20
70
00
ENDCHAR
STARTCHAR uni0198
ENCODING 408
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
80
C0
A0
90
00
ENDCHAR
STARTCHAR uni0199
ENCODING 409
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
80
A0
C0
A0
90
00
ENDCHAR
STARTCHAR uni019A
ENCODING 410
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
20
70
20
20
70
00
ENDCHAR
STARTCHAR uni019B
ENCODING 411
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
30
60
20
50
50
00
ENDCHAR
STARTCHAR uni019C
ENCODING 412
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
90
90
F0
50
00
ENDCHAR
STARTCHAR uni019D
ENCODING 413
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
48
68
68
58
58
48
80
ENDCHAR
STARTCHAR uni019E
ENCODING 414
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
E0
90
90
90
10
ENDCHAR
STARTCHAR uni019F
ENCODING 415
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
F0
90
90
60
00
ENDCHAR
STARTCHAR Ohorn
ENCODING 416
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
68
90
90
90
90
60
00
ENDCHAR
STARTCHAR ohorn
ENCODING 417
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
08
70
90
90
60
00
ENDCHAR
STARTCHAR uni01A2
ENCODING 418
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
A8
A8
A8
A8
40
00
ENDCHAR
STARTCHAR uni01A3
ENCODING 419
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
A8
A8
48
00
ENDCHAR
STARTCHAR uni01A4
ENCODING 420
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
50
50
60
40
40
00
ENDCHAR
STARTCHAR uni01A5
ENCODING 421
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
80
E0
90
90
E0
80
ENDCHAR
STARTCHAR uni01A6
ENCODING 422
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
E0
90
E0
C0
A0
10
ENDCHAR
STARTCHAR uni01A7
ENCODING 423
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
20
40
90
60
00
ENDCHAR
STARTCHAR uni01A8
ENCODING 424
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
E0
30
C0
70
00
ENDCHAR
STARTCHAR uni01A9
ENCODING 425
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
80
40
40
80
F0
00
ENDCHAR
STARTCHAR uni01AA
ENCODING 426
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
A0
70
20
20
20
10
ENDCHAR
STARTCHAR uni01AB
ENCODING 427
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
40
E0
40
70
10
20
ENDCHAR
STARTCHAR uni01AC
ENCODING 428
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
A0
A0
20
20
20
00
ENDCHAR
STARTCHAR uni01AD
ENCODING 429
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
40
E0
40
40
30
00
ENDCHAR
STARTCHAR uni01AE
ENCODING 430
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
40
40
40
40
40
30
ENDCHAR
STARTCHAR Uhorn
ENCODING 431
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
98
90
90
90
90
60
00
ENDCHAR
STARTCHAR uhorn
ENCODING 432
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
08
90
90
90
70
00
ENDCHAR
STARTCHAR uni01B1
ENCODING 433
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
88
88
88
88
70
00
ENDCHAR
STARTCHAR uni01B2
ENCODING 434
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
90
90
90
90
60
00
ENDCHAR
STARTCHAR uni01B3
ENCODING 435
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
50
50
20
20
20
00
ENDCHAR
STARTCHAR uni01B4
ENCODING 436
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
A0
A0
40
80
ENDCHAR
STARTCHAR uni01B5
ENCODING 437
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
10
F0
40
80
F0
00
ENDCHAR
STARTCHAR uni01B6
ENCODING 438
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F0
70
40
F0
00
ENDCHAR
STARTCHAR uni01B7
ENCODING 439
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
20
60
10
10
E0
00
ENDCHAR
STARTCHAR uni01B8
ENCODING 440
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
40
60
80
80
70
00
ENDCHAR
STARTCHAR uni01B9
ENCODING 441
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F0
40
60
80
70
ENDCHAR
STARTCHAR uni01BA
ENCODING 442
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F0
20
60
30
F8
ENDCHAR
STARTCHAR uni01BB
ENCODING 443
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
10
F0
40
F0
00
ENDCHAR
STARTCHAR uni01BC
ENCODING 444
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
80
E0
90
10
E0
00
ENDCHAR
STARTCHAR uni01BD
ENCODING 445
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
60
10
60
00
ENDCHAR
STARTCHAR uni01BE
ENCODING 446
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
20
70
20
10
60
00
ENDCHAR
STARTCHAR uni01BF
ENCODING 447
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
E0
90
A0
C0
80
ENDCHAR
STARTCHAR uni01C0
ENCODING 448
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
20
20
20
20
20
00
ENDCHAR
STARTCHAR uni01C1
ENCODING 449
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
50
50
50
50
50
00
ENDCHAR
STARTCHAR uni01C2
ENCODING 450
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
20
70
20
70
20
00
ENDCHAR
STARTCHAR uni01C3
ENCODING 451
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
20
20
20
00
20
00
ENDCHAR
STARTCHAR uni01C4
ENCODING 452
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
18
D8
A8
A8
B0
D8
00
ENDCHAR
STARTCHAR uni01C5
ENCODING 453
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D8
A0
B8
A8
B0
D8
00
ENDCHAR
STARTCHAR uni01C6
ENCODING 454
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
38
20
78
A8
B0
78
00
ENDCHAR
STARTCHAR uni01C7
ENCODING 455
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
88
88
88
88
A8
D0
00
ENDCHAR
STARTCHAR uni01C8
ENCODING 456
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
88
80
88
88
88
E8
10
ENDCHAR
STARTCHAR uni01C9
ENCODING 457
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
C8
40
48
48
48
E8
10
ENDCHAR
STARTCHAR uni01CA
ENCODING 458
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
C8
A8
A8
A8
A8
B0
00
ENDCHAR
STARTCHAR uni01CB
ENCODING 459
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
C8
A0
A8
A8
A8
A8
10
ENDCHAR
STARTCHAR uni01CC
ENCODING 460
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
08
00
C8
A8
A8
A8
10
ENDCHAR
STARTCHAR uni01CD
ENCODING 461
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
F0
90
90
00
ENDCHAR
STARTCHAR uni01CE
ENCODING 462
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
20
70
90
B0
50
00
ENDCHAR
STARTCHAR uni01CF
ENCODING 463
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
20
20
20
70
00
ENDCHAR
STARTCHAR uni01D0
ENCODING 464
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
20
60
20
20
70
00
ENDCHAR
STARTCHAR uni01D1
ENCODING 465
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
90
90
60
00
ENDCHAR
STARTCHAR uni01D2
ENCODING 466
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
40
60
90
90
60
00
ENDCHAR
STARTCHAR uni01D3
ENCODING 467
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
90
90
90
60
00
ENDCHAR
STARTCHAR uni01D4
ENCODING 468
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
20
90
90
90
70
00
ENDCHAR
STARTCHAR uni01D5
ENCODING 469
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
90
90
90
60
00
ENDCHAR
STARTCHAR uni01D6
ENCODING 470
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
50
00
90
90
70
00
ENDCHAR
STARTCHAR uni01D7
ENCODING 471
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
90
90
90
60
00
ENDCHAR
STARTCHAR uni01D8
ENCODING 472
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
70
00
90
90
70
00
ENDCHAR
STARTCHAR uni01D9
ENCODING 473
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
90
90
90
60
00
ENDCHAR
STARTCHAR uni01DA
ENCODING 474
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
70
00
90
90
70
00
ENDCHAR
STARTCHAR uni01DB
ENCODING 475
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
90
90
90
60
00
ENDCHAR
STARTCHAR uni01DC
ENCODING 476
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
70
00
90
90
70
00
ENDCHAR
STARTCHAR uni01DD
ENCODING 477
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
30
D0
60
00
ENDCHAR
STARTCHAR uni01DE
ENCODING 478
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
F0
90
90
00
ENDCHAR
STARTCHAR uni01DF
ENCODING 479
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
50
70
90
B0
50
00
ENDCHAR
STARTCHAR uni01E0
ENCODING 480
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
F0
90
90
00
ENDCHAR
STARTCHAR uni01E1
ENCODING 481
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
70
90
B0
50
00
ENDCHAR
STARTCHAR uni01E2
ENCODING 482
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
70
A0
F0
A0
B0
00
ENDCHAR
STARTCHAR uni01E3
ENCODING 483
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
00
70
B0
A0
70
00
ENDCHAR
STARTCHAR uni01E4
ENCODING 484
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
80
B0
B8
70
00
ENDCHAR
STARTCHAR uni01E5
ENCODING 485
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
90
60
B8
70
ENDCHAR
STARTCHAR Gcaron
ENCODING 486
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
80
B0
90
70
00
ENDCHAR
STARTCHAR gcaron
ENCODING 487
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
20
70
90
60
80
70
ENDCHAR
STARTCHAR uni01E8
ENCODING 488
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
A0
C0
C0
A0
90
00
ENDCHAR
STARTCHAR uni01E9
ENCODING 489
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
A0
80
A0
C0
A0
00
ENDCHAR
STARTCHAR uni01EA
ENCODING 490
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
90
90
60
40
ENDCHAR
STARTCHAR uni01EB
ENCODING 491
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
90
90
60
40
ENDCHAR
STARTCHAR uni01EC
ENCODING 492
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
90
90
60
40
ENDCHAR
STARTCHAR uni01ED
ENCODING 493
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
00
60
90
90
60
40
ENDCHAR
STARTCHAR uni01EE
ENCODING 494
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
20
60
10
10
E0
00
ENDCHAR
STARTCHAR uni01EF
ENCODING 495
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
20
F0
20
60
10
E0
ENDCHAR
STARTCHAR uni01F0
ENCODING 496
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
20
00
20
20
A0
40
ENDCHAR
STARTCHAR uni01F1
ENCODING 497
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D8
A8
A8
B0
B0
D8
00
ENDCHAR
STARTCHAR uni01F2
ENCODING 498
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
C0
A0
B8
A8
B0
D8
00
ENDCHAR
STARTCHAR uni01F3
ENCODING 499
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
78
A8
B0
78
00
ENDCHAR
STARTCHAR uni01F4
ENCODING 500
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
80
B0
90
70
00
ENDCHAR
STARTCHAR uni01F5
ENCODING 501
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
20
70
90
60
80
70
ENDCHAR
STARTCHAR uni01F6
ENCODING 502
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
A0
E8
A8
A8
90
00
ENDCHAR
STARTCHAR uni01F7
ENCODING 503
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
A0
C0
80
80
00
ENDCHAR
STARTCHAR uni01F8
ENCODING 504
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
D0
D0
B0
B0
90
00
ENDCHAR
STARTCHAR uni01F9
ENCODING 505
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
20
E0
90
90
90
00
ENDCHAR
STARTCHAR Aringacute
ENCODING 506
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
F0
90
90
00
ENDCHAR
STARTCHAR aringacute
ENCODING 507
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
60
60
90
70
00
ENDCHAR
STARTCHAR AEacute
ENCODING 508
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
A0
B0
E0
A0
B0
00
ENDCHAR
STARTCHAR aeacute
ENCODING 509
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
20
70
B0
A0
70
00
ENDCHAR
STARTCHAR Oslashacute
ENCODING 510
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
B0
B0
D0
D0
E0
00
ENDCHAR
STARTCHAR oslashacute
ENCODING 511
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
20
70
B0
D0
E0
00
ENDCHAR
STARTCHAR uni0200
ENCODING 512
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
F0
90
90
00
ENDCHAR
STARTCHAR uni0201
ENCODING 513
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
50
70
90
B0
50
00
ENDCHAR
STARTCHAR uni0202
ENCODING 514
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
F0
90
90
00
ENDCHAR
STARTCHAR uni0203
ENCODING 515
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
70
90
B0
50
00
ENDCHAR
STARTCHAR uni0204
ENCODING 516
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
80
E0
80
80
F0
00
ENDCHAR
STARTCHAR uni0205
ENCODING 517
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
50
60
B0
C0
60
00
ENDCHAR
STARTCHAR uni0206
ENCODING 518
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
80
E0
80
80
F0
00
ENDCHAR
STARTCHAR uni0207
ENCODING 519
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
60
B0
C0
60
00
ENDCHAR
STARTCHAR uni0208
ENCODING 520
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
20
20
20
70
00
ENDCHAR
STARTCHAR uni0209
ENCODING 521
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
50
60
20
20
70
00
ENDCHAR
STARTCHAR uni020A
ENCODING 522
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
20
20
20
70
00
ENDCHAR
STARTCHAR uni020B
ENCODING 523
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
60
20
20
70
00
ENDCHAR
STARTCHAR uni020C
ENCODING 524
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
90
90
60
00
ENDCHAR
STARTCHAR uni020D
ENCODING 525
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
50
60
90
90
60
00
ENDCHAR
STARTCHAR uni020E
ENCODING 526
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
90
90
60
00
ENDCHAR
STARTCHAR uni020F
ENCODING 527
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
60
90
90
60
00
ENDCHAR
STARTCHAR uni0210
ENCODING 528
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
90
E0
A0
90
00
ENDCHAR
STARTCHAR uni0211
ENCODING 529
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
50
E0
90
80
80
00
ENDCHAR
STARTCHAR uni0212
ENCODING 530
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
90
E0
A0
90
00
ENDCHAR
STARTCHAR uni0213
ENCODING 531
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
E0
90
80
80
00
ENDCHAR
STARTCHAR uni0214
ENCODING 532
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
90
90
90
60
00
ENDCHAR
STARTCHAR uni0215
ENCODING 533
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
50
90
90
90
70
00
ENDCHAR
STARTCHAR uni0216
ENCODING 534
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
90
90
90
60
00
ENDCHAR
STARTCHAR uni0217
ENCODING 535
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
90
90
70
00
ENDCHAR
STARTCHAR Scommaaccent
ENCODING 536
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
40
20
90
60
C0
ENDCHAR
STARTCHAR scommaaccent
ENCODING 537
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
C0
30
E0
C0
ENDCHAR
STARTCHAR Tcommaaccent
ENCODING 538
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
20
20
20
20
40
ENDCHAR
STARTCHAR tcommaaccent
ENCODING 539
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
40
E0
40
40
30
40
ENDCHAR
STARTCHAR uni021C
ENCODING 540
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
10
20
10
E0
00
ENDCHAR
STARTCHAR uni021D
ENCODING 541
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
B0
50
20
C0
ENDCHAR
STARTCHAR uni021E
ENCODING 542
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
F0
90
90
90
00
ENDCHAR
STARTCHAR uni021F
ENCODING 543
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
A0
80
E0
90
90
00
ENDCHAR
STARTCHAR uni0250
ENCODING 592
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
A0
D0
90
E0
00
ENDCHAR
STARTCHAR uni0251
ENCODING 593
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
90
90
70
00
ENDCHAR
STARTCHAR uni0252
ENCODING 594
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
E0
90
90
E0
00
ENDCHAR
STARTCHAR uni0253
ENCODING 595
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
80
E0
90
90
E0
00
ENDCHAR
STARTCHAR uni0254
ENCODING 596
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
10
10
60
00
ENDCHAR
STARTCHAR uni0255
ENCODING 597
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
80
B0
60
80
ENDCHAR
STARTCHAR uni0256
ENCODING 598
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
10
70
90
90
70
18
ENDCHAR
STARTCHAR uni0257
ENCODING 599
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
18
10
70
90
90
70
00
ENDCHAR
STARTCHAR uni0258
ENCODING 600
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
D0
30
60
00
ENDCHAR
STARTCHAR uni0259
ENCODING 601
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
30
D0
60
00
ENDCHAR
STARTCHAR uni025A
ENCODING 602
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
38
D0
60
00
ENDCHAR
STARTCHAR uni025B
ENCODING 603
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
30
20
40
30
00
ENDCHAR
STARTCHAR uni025C
ENCODING 604
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
20
10
60
00
ENDCHAR
STARTCHAR uni025D
ENCODING 605
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F0
40
20
C0
00
ENDCHAR
STARTCHAR uni025E
ENCODING 606
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
A0
90
60
00
ENDCHAR
STARTCHAR uni025F
ENCODING 607
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
20
20
70
20
A0
40
ENDCHAR
STARTCHAR uni0260
ENCODING 608
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
08
70
90
70
10
60
ENDCHAR
STARTCHAR uni0261
ENCODING 609
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
90
70
10
60
ENDCHAR
STARTCHAR uni0262
ENCODING 610
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
80
90
70
00
ENDCHAR
STARTCHAR uni0263
ENCODING 611
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
50
20
50
20
ENDCHAR
STARTCHAR uni0264
ENCODING 612
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
20
50
20
00
ENDCHAR
STARTCHAR uni0265
ENCODING 613
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
90
90
70
10
ENDCHAR
STARTCHAR uni0266
ENCODING 614
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
80
E0
90
90
90
00
ENDCHAR
STARTCHAR uni0267
ENCODING 615
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
80
E0
90
90
90
20
ENDCHAR
STARTCHAR uni0268
ENCODING 616
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
00
20
70
20
70
00
ENDCHAR
STARTCHAR uni0269
ENCODING 617
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
40
40
40
20
00
ENDCHAR
STARTCHAR uni026A
ENCODING 618
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
E0
40
40
E0
00
ENDCHAR
STARTCHAR uni026B
ENCODING 619
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
20
68
B0
20
70
00
ENDCHAR
STARTCHAR uni026C
ENCODING 620
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
20
60
70
20
70
00
ENDCHAR
STARTCHAR uni026D
ENCODING 621
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
20
20
20
20
20
10
ENDCHAR
STARTCHAR uni026E
ENCODING 622
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
80
E0
90
90
A0
60
ENDCHAR
STARTCHAR uni026F
ENCODING 623
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
90
F0
50
00
ENDCHAR
STARTCHAR uni0270
ENCODING 624
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
90
F0
50
10
ENDCHAR
STARTCHAR uni0271
ENCODING 625
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
A0
F0
90
90
20
ENDCHAR
STARTCHAR uni0272
ENCODING 626
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
50
50
50
80
ENDCHAR
STARTCHAR uni0273
ENCODING 627
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
C0
A0
A0
A0
10
ENDCHAR
STARTCHAR uni0274
ENCODING 628
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
D0
B0
90
00
ENDCHAR
STARTCHAR uni0275
ENCODING 629
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
60
90
F0
90
60
00
ENDCHAR
STARTCHAR uni0276
ENCODING 630
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
B0
A0
70
00
ENDCHAR
STARTCHAR uni0277
ENCODING 631
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
90
F0
F0
00
ENDCHAR
STARTCHAR uni0278
ENCODING 632
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
20
70
A8
70
20
00
ENDCHAR
STARTCHAR uni0279
ENCODING 633
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
10
10
90
70
00
ENDCHAR
STARTCHAR uni027A
ENCODING 634
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
10
10
10
90
70
00
ENDCHAR
STARTCHAR uni027B
ENCODING 635
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
20
A0
60
30
00
ENDCHAR
STARTCHAR uni027C
ENCODING 636
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
E0
90
80
80
80
80
ENDCHAR
STARTCHAR uni027D
ENCODING 637
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
E0
90
80
80
80
40
ENDCHAR
STARTCHAR uni027E
ENCODING 638
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
90
80
80
00
ENDCHAR
STARTCHAR uni027F
ENCODING 639
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
90
10
10
00
ENDCHAR
STARTCHAR uni0280
ENCODING 640
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
E0
90
E0
90
00
ENDCHAR
STARTCHAR uni0281
ENCODING 641
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
E0
90
E0
00
ENDCHAR
STARTCHAR uni0282
ENCODING 642
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
C0
30
E0
80
ENDCHAR
STARTCHAR uni0283
ENCODING 643
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
20
20
20
20
20
40
ENDCHAR
STARTCHAR uni0284
ENCODING 644
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
20
20
20
70
20
40
ENDCHAR
STARTCHAR uni0285
ENCODING 645
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
40
20
20
10
00
ENDCHAR
STARTCHAR uni0286
ENCODING 646
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
20
20
20
70
A0
40
ENDCHAR
STARTCHAR uni0287
ENCODING 647
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
C0
20
20
70
20
20
ENDCHAR
STARTCHAR uni0288
ENCODING 648
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
40
E0
40
40
40
30
ENDCHAR
STARTCHAR uni0289
ENCODING 649
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
F0
90
70
00
ENDCHAR
STARTCHAR uni028A
ENCODING 650
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
90
90
60
00
ENDCHAR
STARTCHAR uni028B
ENCODING 651
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
A0
90
90
60
00
ENDCHAR
STARTCHAR uni028C
ENCODING 652
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
20
50
50
50
00
ENDCHAR
STARTCHAR uni028D
ENCODING 653
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F0
F0
90
90
00
ENDCHAR
STARTCHAR uni028E
ENCODING 654
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
20
40
A0
90
90
00
ENDCHAR
STARTCHAR uni028F
ENCODING 655
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
A0
40
40
40
00
ENDCHAR
STARTCHAR uni0290
ENCODING 656
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F0
20
40
F0
10
ENDCHAR
STARTCHAR uni0291
ENCODING 657
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F0
20
50
F0
40
ENDCHAR
STARTCHAR uni0292
ENCODING 658
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F0
20
60
10
E0
ENDCHAR
STARTCHAR uni0293
ENCODING 659
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F0
20
60
50
78
ENDCHAR
STARTCHAR uni0294
ENCODING 660
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
60
10
30
20
20
00
ENDCHAR
STARTCHAR uni0295
ENCODING 661
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
30
40
60
20
20
00
ENDCHAR
STARTCHAR uni0296
ENCODING 662
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
20
20
30
10
60
00
ENDCHAR
STARTCHAR uni0297
ENCODING 663
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
20
50
40
40
50
20
ENDCHAR
STARTCHAR uni0298
ENCODING 664
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
70
88
A8
88
70
00
ENDCHAR
STARTCHAR uni0299
ENCODING 665
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
E0
E0
90
E0
00
ENDCHAR
STARTCHAR uni029A
ENCODING 666
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
50
90
60
00
ENDCHAR
STARTCHAR uni029B
ENCODING 667
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
18
70
80
90
70
00
ENDCHAR
STARTCHAR uni029C
ENCODING 668
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
F0
90
90
00
ENDCHAR
STARTCHAR uni029D
ENCODING 669
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
00
20
20
70
A0
40
ENDCHAR
STARTCHAR uni029E
ENCODING 670
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
50
30
50
10
ENDCHAR
STARTCHAR uni029F
ENCODING 671
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
80
80
80
F0
00
ENDCHAR
STARTCHAR uni02A0
ENCODING 672
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
18
70
90
90
70
10
ENDCHAR
STARTCHAR uni02A1
ENCODING 673
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
60
10
20
70
20
00
ENDCHAR
STARTCHAR uni02A2
ENCODING 674
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
30
40
20
70
20
00
ENDCHAR
STARTCHAR uni02A3
ENCODING 675
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
78
A8
B0
78
00
ENDCHAR
STARTCHAR uni02A4
ENCODING 676
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
78
A8
B0
68
10
ENDCHAR
STARTCHAR uni02A5
ENCODING 677
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
78
A8
B8
78
00
ENDCHAR
STARTCHAR uni02A6
ENCODING 678
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
40
E8
50
48
30
00
ENDCHAR
STARTCHAR uni02A7
ENCODING 679
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
48
50
F0
50
50
30
20
ENDCHAR
STARTCHAR uni02A8
ENCODING 680
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
40
E8
50
50
38
10
ENDCHAR
STARTCHAR uni02B6
ENCODING 694
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
C0
A0
C0
00
00
00
ENDCHAR
STARTCHAR uni02B8
ENCODING 696
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
80
00
00
00
00
00
ENDCHAR
STARTCHAR uni02B9
ENCODING 697
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
A0
00
00
00
00
00
ENDCHAR
STARTCHAR afii57929
ENCODING 700
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
20
40
00
00
00
00
ENDCHAR
STARTCHAR afii64937
ENCODING 701
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
20
10
00
00
00
00
ENDCHAR
STARTCHAR circumflex
ENCODING 710
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
50
00
00
00
00
00
ENDCHAR
STARTCHAR caron
ENCODING 711
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
20
00
00
00
00
00
ENDCHAR
STARTCHAR uni02C8
ENCODING 712
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
00
00
00
00
00
ENDCHAR
STARTCHAR macron
ENCODING 713
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
00
00
00
00
00
00
ENDCHAR
STARTCHAR uni02CC
ENCODING 716
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
00
20
20
ENDCHAR
STARTCHAR uni02D0
ENCODING 720
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
70
20
00
20
70
00
ENDCHAR
STARTCHAR uni02D6
ENCODING 726
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
20
70
20
00
00
ENDCHAR
STARTCHAR breve
ENCODING 728
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
60
00
00
00
00
00
ENDCHAR
STARTCHAR dotaccent
ENCODING 729
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
00
00
00
00
00
00
ENDCHAR
STARTCHAR ring
ENCODING 730
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
50
20
00
00
00
00
ENDCHAR
STARTCHAR ogonek
ENCODING 731
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
00
20
30
ENDCHAR
STARTCHAR tilde
ENCODING 732
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
A0
00
00
00
00
00
ENDCHAR
STARTCHAR hungarumlaut
ENCODING 733
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
48
90
00
00
00
00
00
ENDCHAR
STARTCHAR gravecomb
ENCODING 768
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
20
00
00
00
00
00
ENDCHAR
STARTCHAR acutecomb
ENCODING 769
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
00
00
00
00
00
ENDCHAR
STARTCHAR uni0302
ENCODING 770
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
00
00
00
00
00
00
ENDCHAR
STARTCHAR tildecomb
ENCODING 771
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
A0
00
00
00
00
00
ENDCHAR
STARTCHAR uni0304
ENCODING 772
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
00
00
00
00
00
00
ENDCHAR
STARTCHAR uni0305
ENCODING 773
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F8
00
00
00
00
00
00
ENDCHAR
STARTCHAR uni0306
ENCODING 774
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
60
00
00
00
00
00
ENDCHAR
STARTCHAR uni0307
ENCODING 775
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
00
00
00
00
00
00
ENDCHAR
STARTCHAR uni0308
ENCODING 776
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
00
00
00
00
00
ENDCHAR
STARTCHAR hookabovecomb
ENCODING 777
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
20
00
00
00
00
00
ENDCHAR
STARTCHAR uni030A
ENCODING 778
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
60
00
00
00
00
00
ENDCHAR
STARTCHAR uni030B
ENCODING 779
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
48
90
00
00
00
00
00
ENDCHAR
STARTCHAR uni030C
ENCODING 780
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
20
00
00
00
00
00
ENDCHAR
STARTCHAR uni030D
ENCODING 781
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
00
00
00
00
00
ENDCHAR
STARTCHAR uni030E
ENCODING 782
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
00
00
00
00
00
ENDCHAR
STARTCHAR uni030F
ENCODING 783
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
48
00
00
00
00
00
ENDCHAR
STARTCHAR uni0310
ENCODING 784
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A8
70
00
00
00
00
00
ENDCHAR
STARTCHAR uni0311
ENCODING 785
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
00
00
00
00
00
ENDCHAR
STARTCHAR dotbelowcomb
ENCODING 803
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
00
00
20
ENDCHAR
STARTCHAR uni0324
ENCODING 804
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
00
00
50
ENDCHAR
STARTCHAR uni0338
ENCODING 824
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
20
20
40
40
80
00
ENDCHAR
STARTCHAR uni0340
ENCODING 832
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
20
00
00
00
00
00
ENDCHAR
STARTCHAR uni0341
ENCODING 833
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
00
00
00
00
00
ENDCHAR
STARTCHAR uni0374
ENCODING 884
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
00
00
00
00
00
ENDCHAR
STARTCHAR uni0375
ENCODING 885
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
00
20
40
ENDCHAR
STARTCHAR uni037A
ENCODING 890
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
00
00
40
ENDCHAR
STARTCHAR uni037E
ENCODING 894
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
60
60
00
60
40
80
ENDCHAR
STARTCHAR tonos
ENCODING 900
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
00
00
00
00
00
ENDCHAR
STARTCHAR dieresistonos
ENCODING 901
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
B0
40
00
00
00
00
00
ENDCHAR
STARTCHAR Alphatonos
ENCODING 902
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
70
50
50
00
ENDCHAR
STARTCHAR anoteleia
ENCODING 903
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
60
00
00
00
ENDCHAR
STARTCHAR Epsilontonos
ENCODING 904
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
C0
60
40
40
70
00
ENDCHAR
STARTCHAR Etatonos
ENCODING 905
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
D0
70
50
50
50
00
ENDCHAR
STARTCHAR Iotatonos
ENCODING 906
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
A0
20
20
20
70
00
ENDCHAR
STARTCHAR Omicrontonos
ENCODING 908
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
50
50
20
00
ENDCHAR
STARTCHAR Upsilontonos
ENCODING 910
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
D0
50
20
20
20
00
ENDCHAR
STARTCHAR Omegatonos
ENCODING 911
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
50
20
50
00
ENDCHAR
STARTCHAR iotadieresistonos
ENCODING 912
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
B0
40
00
40
40
20
00
ENDCHAR
STARTCHAR Alpha
ENCODING 913
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
F0
90
90
00
ENDCHAR
STARTCHAR Beta
ENCODING 914
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
E0
90
90
E0
00
ENDCHAR
STARTCHAR Gamma
ENCODING 915
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
80
80
80
80
80
00
ENDCHAR
STARTCHAR Delta
ENCODING 916
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
60
90
90
90
F0
00
ENDCHAR
STARTCHAR Epsilon
ENCODING 917
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
80
E0
80
80
F0
00
ENDCHAR
STARTCHAR Zeta
ENCODING 918
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
10
20
40
80
F0
00
ENDCHAR
STARTCHAR Eta
ENCODING 919
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
F0
90
90
90
00
ENDCHAR
STARTCHAR Theta
ENCODING 920
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
F0
90
90
60
00
ENDCHAR
STARTCHAR Iota
ENCODING 921
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
20
20
20
70
00
ENDCHAR
STARTCHAR Kappa
ENCODING 922
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
A0
C0
C0
A0
90
00
ENDCHAR
STARTCHAR Lambda
ENCODING 923
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
60
60
90
90
90
00
ENDCHAR
STARTCHAR Mu
ENCODING 924
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
F0
F0
90
90
90
00
ENDCHAR
STARTCHAR Nu
ENCODING 925
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
D0
D0
B0
B0
90
00
ENDCHAR
STARTCHAR Xi
ENCODING 926
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
00
60
00
00
F0
00
ENDCHAR
STARTCHAR Omicron
ENCODING 927
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
90
90
60
00
ENDCHAR
STARTCHAR Pi
ENCODING 928
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
90
90
90
90
90
00
ENDCHAR
STARTCHAR Rho
ENCODING 929
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
90
E0
80
80
00
ENDCHAR
STARTCHAR Sigma
ENCODING 931
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
80
40
40
80
F0
00
ENDCHAR
STARTCHAR Tau
ENCODING 932
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
20
20
20
20
00
ENDCHAR
STARTCHAR Upsilon
ENCODING 933
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
50
20
20
20
00
ENDCHAR
STARTCHAR Phi
ENCODING 934
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
70
50
50
70
20
00
ENDCHAR
STARTCHAR Chi
ENCODING 935
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
60
60
90
90
00
ENDCHAR
STARTCHAR Psi
ENCODING 936
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
70
70
70
20
20
00
ENDCHAR
STARTCHAR Omega
ENCODING 937
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
50
50
50
20
50
00
ENDCHAR
STARTCHAR Iotadieresis
ENCODING 938
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
70
20
20
70
00
ENDCHAR
STARTCHAR Upsilondieresis
ENCODING 939
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
00
A0
A0
40
40
00
ENDCHAR
STARTCHAR alphatonos
ENCODING 940
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
20
70
90
B0
50
00
ENDCHAR
STARTCHAR epsilontonos
ENCODING 941
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
20
70
20
40
30
00
ENDCHAR
STARTCHAR etatonos
ENCODING 942
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
E0
90
90
90
10
ENDCHAR
STARTCHAR iotatonos
ENCODING 943
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
00
40
40
20
00
ENDCHAR
STARTCHAR upsilondieresistonos
ENCODING 944
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
B0
40
90
90
90
60
00
ENDCHAR
STARTCHAR alpha
ENCODING 945
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
90
B0
50
00
ENDCHAR
STARTCHAR beta
ENCODING 946
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
E0
90
90
E0
80
ENDCHAR
STARTCHAR gamma
ENCODING 947
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
50
20
20
20
ENDCHAR
STARTCHAR delta
ENCODING 948
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
80
60
90
90
60
00
ENDCHAR
STARTCHAR epsilon
ENCODING 949
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
20
40
30
00
ENDCHAR
STARTCHAR zeta
ENCODING 950
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
40
80
80
80
70
10
ENDCHAR
STARTCHAR eta
ENCODING 951
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
E0
90
90
90
10
ENDCHAR
STARTCHAR theta
ENCODING 952
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
50
70
50
50
20
00
ENDCHAR
STARTCHAR iota
ENCODING 953
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
40
40
40
20
00
ENDCHAR
STARTCHAR kappa
ENCODING 954
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
A0
E0
90
00
ENDCHAR
STARTCHAR lambda
ENCODING 955
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
10
50
B0
90
90
00
ENDCHAR
STARTCHAR mu
ENCODING 956
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
90
90
F0
80
ENDCHAR
STARTCHAR nu
ENCODING 957
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
50
50
20
00
ENDCHAR
STARTCHAR xi
ENCODING 958
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
40
80
60
80
70
10
ENDCHAR
STARTCHAR omicron
ENCODING 959
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
90
90
60
00
ENDCHAR
STARTCHAR pi
ENCODING 960
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
50
50
50
00
ENDCHAR
STARTCHAR rho
ENCODING 961
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
90
90
E0
80
ENDCHAR
STARTCHAR sigma1
ENCODING 962
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
C0
30
60
00
ENDCHAR
STARTCHAR sigma
ENCODING 963
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
A0
90
60
00
ENDCHAR
STARTCHAR tau
ENCODING 964
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F0
40
40
20
00
ENDCHAR
STARTCHAR upsilon
ENCODING 965
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
90
90
60
00
ENDCHAR
STARTCHAR phi
ENCODING 966
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
20
70
50
70
20
ENDCHAR
STARTCHAR chi
ENCODING 967
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
60
60
90
90
ENDCHAR
STARTCHAR psi
ENCODING 968
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
70
70
20
20
ENDCHAR
STARTCHAR omega
ENCODING 969
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
90
F0
F0
00
ENDCHAR
STARTCHAR iotadieresis
ENCODING 970
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
00
40
40
40
20
00
ENDCHAR
STARTCHAR upsilondieresis
ENCODING 971
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
00
90
90
90
60
00
ENDCHAR
STARTCHAR omicrontonos
ENCODING 972
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
60
90
90
60
00
ENDCHAR
STARTCHAR upsilontonos
ENCODING 973
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
90
90
90
60
00
ENDCHAR
STARTCHAR omegatonos
ENCODING 974
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
90
90
F0
F0
00
ENDCHAR
STARTCHAR uni03D0
ENCODING 976
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
A0
D0
90
60
00
ENDCHAR
STARTCHAR theta1
ENCODING 977
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
70
10
90
60
00
ENDCHAR
STARTCHAR Upsilon1
ENCODING 978
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
50
20
20
20
00
ENDCHAR
STARTCHAR uni03D3
ENCODING 979
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
D0
50
20
20
20
00
ENDCHAR
STARTCHAR uni03D4
ENCODING 980
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
50
50
20
20
00
ENDCHAR
STARTCHAR phi1
ENCODING 981
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
20
70
50
70
20
ENDCHAR
STARTCHAR omega1
ENCODING 982
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F0
90
F0
F0
00
ENDCHAR
STARTCHAR uni03D7
ENCODING 983
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
20
90
60
60
90
30
ENDCHAR
STARTCHAR uni03DA
ENCODING 986
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
50
80
80
60
10
20
ENDCHAR
STARTCHAR uni03DB
ENCODING 987
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
C0
30
60
00
ENDCHAR
STARTCHAR uni03DC
ENCODING 988
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
80
E0
80
80
80
00
ENDCHAR
STARTCHAR uni03DD
ENCODING 989
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
40
60
40
40
ENDCHAR
STARTCHAR uni03DE
ENCODING 990
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
90
B0
D0
90
10
00
ENDCHAR
STARTCHAR uni03DF
ENCODING 991
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
40
80
F0
10
20
20
ENDCHAR
STARTCHAR uni03E0
ENCODING 992
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
60
60
90
B0
B0
00
ENDCHAR
STARTCHAR uni03E1
ENCODING 993
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
C0
20
50
B0
50
10
10
ENDCHAR
STARTCHAR uni03F0
ENCODING 1008
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
60
60
B0
00
ENDCHAR
STARTCHAR uni03F1
ENCODING 1009
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
90
E0
80
60
ENDCHAR
STARTCHAR uni03F2
ENCODING 1010
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
30
40
40
30
00
ENDCHAR
STARTCHAR uni03F3
ENCODING 1011
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
10
10
10
50
20
ENDCHAR
STARTCHAR uni03F4
ENCODING 1012
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
F0
90
90
60
00
ENDCHAR
STARTCHAR uni03F5
ENCODING 1013
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
30
60
40
30
00
ENDCHAR
STARTCHAR afii10023
ENCODING 1025
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
80
E0
80
80
F0
00
ENDCHAR
STARTCHAR afii10051
ENCODING 1026
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
40
60
50
50
10
20
ENDCHAR
STARTCHAR afii10052
ENCODING 1027
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
80
80
80
80
80
00
ENDCHAR
STARTCHAR afii10053
ENCODING 1028
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
C0
80
90
60
00
ENDCHAR
STARTCHAR afii10054
ENCODING 1029
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
40
20
90
60
00
ENDCHAR
STARTCHAR afii10055
ENCODING 1030
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
20
20
20
70
00
ENDCHAR
STARTCHAR afii10056
ENCODING 1031
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
20
20
20
70
00
ENDCHAR
STARTCHAR afii10057
ENCODING 1032
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
10
10
10
90
60
00
ENDCHAR
STARTCHAR afii10058
ENCODING 1033
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
A0
B0
A8
A8
B0
00
ENDCHAR
STARTCHAR afii10059
ENCODING 1034
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
A0
F0
A8
A8
B0
00
ENDCHAR
STARTCHAR afii10060
ENCODING 1035
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
40
60
50
50
50
00
ENDCHAR
STARTCHAR afii10061
ENCODING 1036
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
A0
C0
C0
A0
90
00
ENDCHAR
STARTCHAR afii10062
ENCODING 1038
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
50
20
20
40
00
ENDCHAR
STARTCHAR afii10145
ENCODING 1039
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
50
50
50
70
20
ENDCHAR
STARTCHAR afii10017
ENCODING 1040
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
F0
90
90
00
ENDCHAR
STARTCHAR afii10018
ENCODING 1041
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
80
E0
90
90
E0
00
ENDCHAR
STARTCHAR afii10019
ENCODING 1042
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
E0
90
90
E0
00
ENDCHAR
STARTCHAR afii10020
ENCODING 1043
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
80
80
80
80
80
00
ENDCHAR
STARTCHAR afii10021
ENCODING 1044
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
50
50
50
50
F0
90
ENDCHAR
STARTCHAR afii10022
ENCODING 1045
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
80
E0
80
80
F0
00
ENDCHAR
STARTCHAR afii10024
ENCODING 1046
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A8
A8
70
70
A8
A8
00
ENDCHAR
STARTCHAR afii10025
ENCODING 1047
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
10
60
10
90
60
00
ENDCHAR
STARTCHAR afii10026
ENCODING 1048
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
B0
B0
D0
D0
90
00
ENDCHAR
STARTCHAR afii10027
ENCODING 1049
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
B0
B0
D0
D0
90
00
ENDCHAR
STARTCHAR afii10028
ENCODING 1050
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
A0
C0
C0
A0
90
00
ENDCHAR
STARTCHAR afii10029
ENCODING 1051
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
50
50
50
50
90
00
ENDCHAR
STARTCHAR afii10030
ENCODING 1052
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
F0
F0
90
90
90
00
ENDCHAR
STARTCHAR afii10031
ENCODING 1053
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
F0
90
90
90
00
ENDCHAR
STARTCHAR afii10032
ENCODING 1054
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
90
90
60
00
ENDCHAR
STARTCHAR afii10033
ENCODING 1055
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
90
90
90
90
90
00
ENDCHAR
STARTCHAR afii10034
ENCODING 1056
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
90
E0
80
80
00
ENDCHAR
STARTCHAR afii10035
ENCODING 1057
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
80
80
90
60
00
ENDCHAR
STARTCHAR afii10036
ENCODING 1058
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
20
20
20
20
00
ENDCHAR
STARTCHAR afii10037
ENCODING 1059
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
50
20
20
40
00
ENDCHAR
STARTCHAR afii10038
ENCODING 1060
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
70
50
50
70
20
00
ENDCHAR
STARTCHAR afii10039
ENCODING 1061
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
60
60
90
90
00
ENDCHAR
STARTCHAR afii10040
ENCODING 1062
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
90
90
90
F0
10
ENDCHAR
STARTCHAR afii10041
ENCODING 1063
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
90
70
10
10
00
ENDCHAR
STARTCHAR afii10042
ENCODING 1064
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A8
A8
A8
A8
A8
F8
00
ENDCHAR
STARTCHAR afii10043
ENCODING 1065
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A8
A8
A8
A8
A8
F8
08
ENDCHAR
STARTCHAR afii10044
ENCODING 1066
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
C0
40
60
50
50
60
00
ENDCHAR
STARTCHAR afii10045
ENCODING 1067
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
D0
B0
B0
D0
00
ENDCHAR
STARTCHAR afii10046
ENCODING 1068
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
80
E0
90
90
E0
00
ENDCHAR
STARTCHAR afii10047
ENCODING 1069
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
30
10
90
60
00
ENDCHAR
STARTCHAR afii10048
ENCODING 1070
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
D0
D0
D0
A0
00
ENDCHAR
STARTCHAR afii10049
ENCODING 1071
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
90
90
70
50
90
00
ENDCHAR
STARTCHAR afii10065
ENCODING 1072
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
90
B0
50
00
ENDCHAR
STARTCHAR afii10066
ENCODING 1073
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
60
80
E0
90
60
00
ENDCHAR
STARTCHAR afii10067
ENCODING 1074
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
E0
E0
90
E0
00
ENDCHAR
STARTCHAR afii10068
ENCODING 1075
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F0
80
80
80
00
ENDCHAR
STARTCHAR afii10069
ENCODING 1076
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
30
50
50
F0
90
ENDCHAR
STARTCHAR afii10070
ENCODING 1077
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
B0
C0
60
00
ENDCHAR
STARTCHAR afii10072
ENCODING 1078
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
A8
70
70
A8
00
ENDCHAR
STARTCHAR afii10073
ENCODING 1079
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
E0
60
20
C0
00
ENDCHAR
STARTCHAR afii10074
ENCODING 1080
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
B0
D0
90
00
ENDCHAR
STARTCHAR afii10075
ENCODING 1081
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
60
90
B0
D0
90
00
ENDCHAR
STARTCHAR afii10076
ENCODING 1082
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
E0
A0
90
00
ENDCHAR
STARTCHAR afii10077
ENCODING 1083
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
30
50
50
90
00
ENDCHAR
STARTCHAR afii10078
ENCODING 1084
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
88
D8
A8
A8
00
ENDCHAR
STARTCHAR afii10079
ENCODING 1085
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
F0
90
90
00
ENDCHAR
STARTCHAR afii10080
ENCODING 1086
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
90
90
60
00
ENDCHAR
STARTCHAR afii10081
ENCODING 1087
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F0
90
90
90
00
ENDCHAR
STARTCHAR afii10082
ENCODING 1088
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
E0
90
90
E0
80
ENDCHAR
STARTCHAR afii10083
ENCODING 1089
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
80
80
60
00
ENDCHAR
STARTCHAR afii10084
ENCODING 1090
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
E0
40
40
40
00
ENDCHAR
STARTCHAR afii10085
ENCODING 1091
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
90
50
20
40
ENDCHAR
STARTCHAR afii10086
ENCODING 1092
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
20
20
70
50
70
20
ENDCHAR
STARTCHAR afii10087
ENCODING 1093
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
60
60
90
00
ENDCHAR
STARTCHAR afii10088
ENCODING 1094
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
90
90
F0
10
ENDCHAR
STARTCHAR afii10089
ENCODING 1095
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
90
70
10
00
ENDCHAR
STARTCHAR afii10090
ENCODING 1096
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
A8
A8
A8
F8
00
ENDCHAR
STARTCHAR afii10091
ENCODING 1097
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
A8
A8
A8
F8
08
ENDCHAR
STARTCHAR afii10092
ENCODING 1098
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
C0
60
50
60
00
ENDCHAR
STARTCHAR afii10093
ENCODING 1099
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
D0
B0
D0
00
ENDCHAR
STARTCHAR afii10094
ENCODING 1100
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
80
E0
90
E0
00
ENDCHAR
STARTCHAR afii10095
ENCODING 1101
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
30
10
60
00
ENDCHAR
STARTCHAR afii10096
ENCODING 1102
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
A0
D0
D0
A0
00
ENDCHAR
STARTCHAR afii10097
ENCODING 1103
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
A0
60
A0
00
ENDCHAR
STARTCHAR afii10071
ENCODING 1105
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
00
60
B0
C0
60
00
ENDCHAR
STARTCHAR afii10099
ENCODING 1106
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
E0
40
60
50
10
20
ENDCHAR
STARTCHAR afii10100
ENCODING 1107
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
F0
80
80
80
00
ENDCHAR
STARTCHAR afii10101
ENCODING 1108
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
30
60
40
30
00
ENDCHAR
STARTCHAR afii10102
ENCODING 1109
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
C0
30
E0
00
ENDCHAR
STARTCHAR afii10103
ENCODING 1110
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
00
60
20
20
70
00
ENDCHAR
STARTCHAR afii10104
ENCODING 1111
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
60
20
20
70
00
ENDCHAR
STARTCHAR afii10105
ENCODING 1112
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
10
10
10
50
20
ENDCHAR
STARTCHAR afii10106
ENCODING 1113
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
B8
A8
B0
00
ENDCHAR
STARTCHAR afii10107
ENCODING 1114
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
A0
F0
A8
B0
00
ENDCHAR
STARTCHAR afii10108
ENCODING 1115
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
E0
40
70
48
48
00
ENDCHAR
STARTCHAR afii10109
ENCODING 1116
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
90
E0
A0
90
00
ENDCHAR
STARTCHAR afii10110
ENCODING 1118
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
60
00
90
50
20
40
ENDCHAR
STARTCHAR afii10193
ENCODING 1119
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
50
50
70
20
ENDCHAR
STARTCHAR afii10050
ENCODING 1168
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
F0
80
80
80
80
00
ENDCHAR
STARTCHAR afii10098
ENCODING 1169
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
10
F0
80
80
80
00
ENDCHAR
STARTCHAR uni0492
ENCODING 1170
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
70
40
E0
40
40
00
ENDCHAR
STARTCHAR uni0493
ENCODING 1171
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
40
E0
40
00
ENDCHAR
STARTCHAR uni0496
ENCODING 1174
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A8
A8
70
70
A8
A8
08
ENDCHAR
STARTCHAR uni0497
ENCODING 1175
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
A8
70
70
A8
08
ENDCHAR
STARTCHAR uni049A
ENCODING 1178
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
A0
C0
C0
A0
90
08
ENDCHAR
STARTCHAR uni049B
ENCODING 1179
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
E0
A0
90
08
ENDCHAR
STARTCHAR uni04AE
ENCODING 1198
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
50
20
20
20
00
ENDCHAR
STARTCHAR uni04AF
ENCODING 1199
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
50
20
20
20
ENDCHAR
STARTCHAR uni04B0
ENCODING 1200
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
20
70
20
20
00
ENDCHAR
STARTCHAR uni04B1
ENCODING 1201
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
20
70
20
20
ENDCHAR
STARTCHAR uni04B2
ENCODING 1202
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
60
60
90
90
08
ENDCHAR
STARTCHAR uni04B3
ENCODING 1203
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
60
60
90
08
ENDCHAR
STARTCHAR uni04BA
ENCODING 1210
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
80
E0
90
90
90
00
ENDCHAR
STARTCHAR uni04BB
ENCODING 1211
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
40
60
50
50
50
00
ENDCHAR
STARTCHAR uni04D8
ENCODING 1240
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
10
F0
90
60
00
ENDCHAR
STARTCHAR afii10846
ENCODING 1241
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
30
D0
60
00
ENDCHAR
STARTCHAR uni04E2
ENCODING 1250
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
20
20
20
70
00
ENDCHAR
STARTCHAR uni04E3
ENCODING 1251
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
00
60
20
20
70
00
ENDCHAR
STARTCHAR uni04E8
ENCODING 1256
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
F0
90
90
60
00
ENDCHAR
STARTCHAR uni04E9
ENCODING 1257
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
F0
90
60
00
ENDCHAR
STARTCHAR uni04EE
ENCODING 1262
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
90
90
90
60
00
ENDCHAR
STARTCHAR uni04EF
ENCODING 1263
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
00
90
90
90
70
00
ENDCHAR
STARTCHAR afii57664
ENCODING 1488
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
50
A0
90
00
ENDCHAR
STARTCHAR afii57665
ENCODING 1489
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
E0
20
20
F0
00
ENDCHAR
STARTCHAR afii57666
ENCODING 1490
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
40
20
20
20
D0
00
ENDCHAR
STARTCHAR afii57667
ENCODING 1491
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F0
20
20
20
00
ENDCHAR
STARTCHAR afii57668
ENCODING 1492
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F0
10
90
90
00
ENDCHAR
STARTCHAR afii57669
ENCODING 1493
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
40
20
20
20
20
00
ENDCHAR
STARTCHAR afii57670
ENCODING 1494
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
20
20
20
00
ENDCHAR
STARTCHAR afii57671
ENCODING 1495
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F0
50
50
50
00
ENDCHAR
STARTCHAR afii57672
ENCODING 1496
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
90
90
F0
00
ENDCHAR
STARTCHAR afii57673
ENCODING 1497
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
40
20
00
00
00
00
ENDCHAR
STARTCHAR afii57674
ENCODING 1498
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F0
10
20
20
00
ENDCHAR
STARTCHAR afii57675
ENCODING 1499
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
80
70
10
10
E0
00
ENDCHAR
STARTCHAR afii57676
ENCODING 1500
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
80
70
10
20
40
00
ENDCHAR
STARTCHAR afii57677
ENCODING 1501
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
80
70
90
90
F0
00
ENDCHAR
STARTCHAR afii57678
ENCODING 1502
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
80
70
90
90
B0
00
ENDCHAR
STARTCHAR afii57679
ENCODING 1503
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
40
20
40
40
40
00
ENDCHAR
STARTCHAR afii57680
ENCODING 1504
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
40
20
20
20
60
00
ENDCHAR
STARTCHAR afii57681
ENCODING 1505
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
80
78
48
48
30
00
ENDCHAR
STARTCHAR afii57682
ENCODING 1506
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
50
50
F0
00
ENDCHAR
STARTCHAR afii57683
ENCODING 1507
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
90
10
10
00
ENDCHAR
STARTCHAR afii57684
ENCODING 1508
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F0
90
10
F0
00
ENDCHAR
STARTCHAR afii57685
ENCODING 1509
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
60
40
40
00
ENDCHAR
STARTCHAR afii57686
ENCODING 1510
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
60
20
F0
00
ENDCHAR
STARTCHAR afii57687
ENCODING 1511
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
E0
10
A0
80
00
ENDCHAR
STARTCHAR afii57688
ENCODING 1512
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F0
10
10
10
00
ENDCHAR
STARTCHAR afii57689
ENCODING 1513
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
A8
C8
88
F0
00
ENDCHAR
STARTCHAR afii57690
ENCODING 1514
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F0
50
50
D0
00
ENDCHAR
STARTCHAR uni16A0
ENCODING 5792
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
60
50
60
40
40
00
ENDCHAR
STARTCHAR uni16A2
ENCODING 5794
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
50
50
50
50
50
00
ENDCHAR
STARTCHAR uni16A3
ENCODING 5795
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
50
50
70
70
70
00
ENDCHAR
STARTCHAR uni16A6
ENCODING 5798
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
60
50
50
60
40
00
ENDCHAR
STARTCHAR uni16A9
ENCODING 5801
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
A0
80
80
80
80
00
ENDCHAR
STARTCHAR uni16AA
ENCODING 5802
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
A0
80
C0
A0
80
00
ENDCHAR
STARTCHAR uni16AB
ENCODING 5803
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
50
60
50
40
40
00
ENDCHAR
STARTCHAR uni16B1
ENCODING 5809
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
A0
C0
A0
80
00
ENDCHAR
STARTCHAR uni16B3
ENCODING 5811
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
40
60
50
50
50
00
ENDCHAR
STARTCHAR uni16B7
ENCODING 5815
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
20
20
50
50
00
ENDCHAR
STARTCHAR uni16B8
ENCODING 5816
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
70
A8
A8
70
50
00
ENDCHAR
STARTCHAR uni16B9
ENCODING 5817
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
50
50
60
40
40
00
ENDCHAR
STARTCHAR uni16BB
ENCODING 5819
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
D0
B0
D0
B0
00
ENDCHAR
STARTCHAR uni16BE
ENCODING 5822
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
60
30
20
20
00
ENDCHAR
STARTCHAR uni16C0
ENCODING 5824
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
20
20
20
20
00
ENDCHAR
STARTCHAR uni16C4
ENCODING 5828
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
70
A8
A8
70
20
00
ENDCHAR
STARTCHAR uni16C7
ENCODING 5831
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
30
28
A0
60
20
00
ENDCHAR
STARTCHAR uni16C8
ENCODING 5832
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
A0
80
80
A0
D0
00
ENDCHAR
STARTCHAR uni16C9
ENCODING 5833
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A8
A8
A8
70
20
20
00
ENDCHAR
STARTCHAR uni16CB
ENCODING 5835
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
90
B0
D0
90
10
00
ENDCHAR
STARTCHAR uni16CF
ENCODING 5839
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
70
A8
20
20
20
00
ENDCHAR
STARTCHAR uni16D2
ENCODING 5842
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
E0
E0
90
E0
00
ENDCHAR
STARTCHAR uni16D6
ENCODING 5846
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
88
D8
A8
88
88
88
00
ENDCHAR
STARTCHAR uni16D7
ENCODING 5847
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
88
D8
A8
D8
88
88
00
ENDCHAR
STARTCHAR uni16DA
ENCODING 5850
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
60
50
40
40
40
00
ENDCHAR
STARTCHAR uni16DD
ENCODING 5853
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
20
50
50
20
50
00
ENDCHAR
STARTCHAR uni16DE
ENCODING 5854
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
88
88
D8
A8
D8
88
00
ENDCHAR
STARTCHAR uni16DF
ENCODING 5855
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
50
50
20
50
50
00
ENDCHAR
STARTCHAR uni16E0
ENCODING 5856
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A8
70
20
20
20
20
00
ENDCHAR
STARTCHAR uni16E1
ENCODING 5857
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A8
70
70
A8
20
20
00
ENDCHAR
STARTCHAR uni16E2
ENCODING 5858
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
28
30
20
20
60
A0
00
ENDCHAR
STARTCHAR uni16E3
ENCODING 5859
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
20
70
A8
A8
00
ENDCHAR
STARTCHAR uni16E4
ENCODING 5860
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
F0
90
90
F0
90
00
ENDCHAR
STARTCHAR uni16EB
ENCODING 5867
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
20
00
00
00
ENDCHAR
STARTCHAR uni16EC
ENCODING 5868
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
20
00
20
00
00
ENDCHAR
STARTCHAR uni16ED
ENCODING 5869
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
20
50
00
00
ENDCHAR
STARTCHAR uni1E02
ENCODING 7682
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
E0
90
90
E0
00
ENDCHAR
STARTCHAR uni1E03
ENCODING 7683
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
80
80
E0
90
E0
00
ENDCHAR
STARTCHAR uni1E0A
ENCODING 7690
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
90
90
90
E0
00
ENDCHAR
STARTCHAR uni1E0B
ENCODING 7691
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
10
10
70
90
70
00
ENDCHAR
STARTCHAR uni1E1E
ENCODING 7710
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
80
E0
80
80
80
00
ENDCHAR
STARTCHAR uni1E1F
ENCODING 7711
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
20
40
E0
40
40
00
ENDCHAR
STARTCHAR uni1E40
ENCODING 7744
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
F0
F0
90
90
90
00
ENDCHAR
STARTCHAR uni1E41
ENCODING 7745
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
00
A0
F0
90
90
00
ENDCHAR
STARTCHAR uni1E56
ENCODING 7766
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
90
E0
80
80
00
ENDCHAR
STARTCHAR uni1E57
ENCODING 7767
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
00
E0
90
90
E0
80
ENDCHAR
STARTCHAR uni1E60
ENCODING 7776
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
40
20
90
60
00
ENDCHAR
STARTCHAR uni1E61
ENCODING 7777
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
00
70
C0
30
E0
00
ENDCHAR
STARTCHAR uni1E6A
ENCODING 7786
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
20
20
20
20
00
ENDCHAR
STARTCHAR uni1E6B
ENCODING 7787
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
20
70
20
20
10
00
ENDCHAR
STARTCHAR Wgrave
ENCODING 7808
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
90
F0
F0
90
00
ENDCHAR
STARTCHAR wgrave
ENCODING 7809
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
20
00
90
F0
F0
00
ENDCHAR
STARTCHAR Wacute
ENCODING 7810
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
90
F0
F0
90
00
ENDCHAR
STARTCHAR wacute
ENCODING 7811
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
00
90
F0
F0
00
ENDCHAR
STARTCHAR Wdieresis
ENCODING 7812
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
90
F0
F0
90
00
ENDCHAR
STARTCHAR wdieresis
ENCODING 7813
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
A0
00
90
F0
F0
00
ENDCHAR
STARTCHAR Ygrave
ENCODING 7922
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
50
20
20
20
00
ENDCHAR
STARTCHAR ygrave
ENCODING 7923
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
20
00
90
50
20
40
ENDCHAR
STARTCHAR uni1F00
ENCODING 7936
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
20
70
90
B0
50
00
ENDCHAR
STARTCHAR uni1F01
ENCODING 7937
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
40
70
90
B0
50
00
ENDCHAR
STARTCHAR uni1F02
ENCODING 7938
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
50
70
90
B0
50
00
ENDCHAR
STARTCHAR uni1F03
ENCODING 7939
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
70
90
B0
50
00
ENDCHAR
STARTCHAR uni1F04
ENCODING 7940
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
60
70
90
B0
50
00
ENDCHAR
STARTCHAR uni1F05
ENCODING 7941
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
A0
70
90
B0
50
00
ENDCHAR
STARTCHAR uni1F06
ENCODING 7942
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
70
90
B0
50
00
ENDCHAR
STARTCHAR uni1F07
ENCODING 7943
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
70
90
B0
50
00
ENDCHAR
STARTCHAR uni1F08
ENCODING 7944
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
70
50
50
00
ENDCHAR
STARTCHAR uni1F09
ENCODING 7945
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
70
50
50
00
ENDCHAR
STARTCHAR uni1F0A
ENCODING 7946
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
70
50
50
00
ENDCHAR
STARTCHAR uni1F0B
ENCODING 7947
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
70
50
50
00
ENDCHAR
STARTCHAR uni1F0C
ENCODING 7948
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
70
50
50
00
ENDCHAR
STARTCHAR uni1F0D
ENCODING 7949
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
70
50
50
00
ENDCHAR
STARTCHAR uni1F0E
ENCODING 7950
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
70
50
50
00
ENDCHAR
STARTCHAR uni1F0F
ENCODING 7951
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
70
50
50
00
ENDCHAR
STARTCHAR uni1F10
ENCODING 7952
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
10
70
20
40
30
00
ENDCHAR
STARTCHAR uni1F11
ENCODING 7953
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
20
70
20
40
30
00
ENDCHAR
STARTCHAR uni1F12
ENCODING 7954
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
50
E0
40
80
60
00
ENDCHAR
STARTCHAR uni1F13
ENCODING 7955
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
E0
40
80
60
00
ENDCHAR
STARTCHAR uni1F14
ENCODING 7956
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
60
E0
40
80
60
00
ENDCHAR
STARTCHAR uni1F15
ENCODING 7957
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
A0
E0
40
80
60
00
ENDCHAR
STARTCHAR uni1F18
ENCODING 7960
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
C0
60
40
40
70
00
ENDCHAR
STARTCHAR uni1F19
ENCODING 7961
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
C0
60
40
40
70
00
ENDCHAR
STARTCHAR uni1F1A
ENCODING 7962
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
C0
60
40
40
70
00
ENDCHAR
STARTCHAR uni1F1B
ENCODING 7963
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
C0
60
40
40
70
00
ENDCHAR
STARTCHAR uni1F1C
ENCODING 7964
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
C0
60
40
40
70
00
ENDCHAR
STARTCHAR uni1F1D
ENCODING 7965
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
C0
60
40
40
70
00
ENDCHAR
STARTCHAR uni1F20
ENCODING 7968
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
20
E0
90
90
90
10
ENDCHAR
STARTCHAR uni1F21
ENCODING 7969
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
40
E0
90
90
90
10
ENDCHAR
STARTCHAR uni1F22
ENCODING 7970
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
50
E0
90
90
90
10
ENDCHAR
STARTCHAR uni1F23
ENCODING 7971
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
E0
90
90
90
10
ENDCHAR
STARTCHAR uni1F24
ENCODING 7972
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
60
E0
90
90
90
10
ENDCHAR
STARTCHAR uni1F25
ENCODING 7973
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
A0
E0
90
90
90
10
ENDCHAR
STARTCHAR uni1F26
ENCODING 7974
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
E0
90
90
90
10
ENDCHAR
STARTCHAR uni1F27
ENCODING 7975
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
E0
90
90
90
10
ENDCHAR
STARTCHAR uni1F28
ENCODING 7976
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
D0
70
50
50
50
00
ENDCHAR
STARTCHAR uni1F29
ENCODING 7977
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
D0
70
50
50
50
00
ENDCHAR
STARTCHAR uni1F2A
ENCODING 7978
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
D0
70
50
50
50
00
ENDCHAR
STARTCHAR uni1F2B
ENCODING 7979
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
D0
70
50
50
50
00
ENDCHAR
STARTCHAR uni1F2C
ENCODING 7980
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
D0
70
50
50
50
00
ENDCHAR
STARTCHAR uni1F2D
ENCODING 7981
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
D0
70
50
50
50
00
ENDCHAR
STARTCHAR uni1F2E
ENCODING 7982
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
D0
70
50
50
50
00
ENDCHAR
STARTCHAR uni1F2F
ENCODING 7983
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
D0
70
50
50
50
00
ENDCHAR
STARTCHAR uni1F30
ENCODING 7984
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
20
00
40
40
20
00
ENDCHAR
STARTCHAR uni1F31
ENCODING 7985
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
40
00
40
40
20
00
ENDCHAR
STARTCHAR uni1F32
ENCODING 7986
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
50
00
40
40
20
00
ENDCHAR
STARTCHAR uni1F33
ENCODING 7987
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
00
40
40
20
00
ENDCHAR
STARTCHAR uni1F34
ENCODING 7988
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
60
00
40
40
20
00
ENDCHAR
STARTCHAR uni1F35
ENCODING 7989
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
A0
00
40
40
20
00
ENDCHAR
STARTCHAR uni1F36
ENCODING 7990
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
40
00
40
40
20
00
ENDCHAR
STARTCHAR uni1F37
ENCODING 7991
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
40
00
40
40
20
00
ENDCHAR
STARTCHAR uni1F38
ENCODING 7992
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
A0
20
20
20
70
00
ENDCHAR
STARTCHAR uni1F39
ENCODING 7993
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
A0
20
20
20
70
00
ENDCHAR
STARTCHAR uni1F3A
ENCODING 7994
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
A0
20
20
20
70
00
ENDCHAR
STARTCHAR uni1F3B
ENCODING 7995
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
A0
20
20
20
70
00
ENDCHAR
STARTCHAR uni1F3C
ENCODING 7996
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
A0
20
20
20
70
00
ENDCHAR
STARTCHAR uni1F3D
ENCODING 7997
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
A0
20
20
20
70
00
ENDCHAR
STARTCHAR uni1F3E
ENCODING 7998
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
A0
20
20
20
70
00
ENDCHAR
STARTCHAR uni1F3F
ENCODING 7999
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
A0
20
20
20
70
00
ENDCHAR
STARTCHAR uni1F40
ENCODING 8000
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
20
60
90
90
60
00
ENDCHAR
STARTCHAR uni1F41
ENCODING 8001
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
40
60
90
90
60
00
ENDCHAR
STARTCHAR uni1F42
ENCODING 8002
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
50
60
90
90
60
00
ENDCHAR
STARTCHAR uni1F43
ENCODING 8003
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
60
90
90
60
00
ENDCHAR
STARTCHAR uni1F44
ENCODING 8004
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
60
60
90
90
60
00
ENDCHAR
STARTCHAR uni1F45
ENCODING 8005
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
A0
60
90
90
60
00
ENDCHAR
STARTCHAR uni1F48
ENCODING 8008
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
50
50
20
00
ENDCHAR
STARTCHAR uni1F49
ENCODING 8009
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
50
50
20
00
ENDCHAR
STARTCHAR uni1F4A
ENCODING 8010
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
50
50
20
00
ENDCHAR
STARTCHAR uni1F4B
ENCODING 8011
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
50
50
20
00
ENDCHAR
STARTCHAR uni1F4C
ENCODING 8012
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
50
50
20
00
ENDCHAR
STARTCHAR uni1F4D
ENCODING 8013
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
50
50
20
00
ENDCHAR
STARTCHAR uni1F50
ENCODING 8016
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
20
90
90
90
60
00
ENDCHAR
STARTCHAR uni1F51
ENCODING 8017
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
40
90
90
90
60
00
ENDCHAR
STARTCHAR uni1F52
ENCODING 8018
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
50
90
90
90
60
00
ENDCHAR
STARTCHAR uni1F53
ENCODING 8019
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
90
90
90
60
00
ENDCHAR
STARTCHAR uni1F54
ENCODING 8020
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
60
90
90
90
60
00
ENDCHAR
STARTCHAR uni1F55
ENCODING 8021
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
A0
90
90
90
60
00
ENDCHAR
STARTCHAR uni1F56
ENCODING 8022
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
90
90
90
60
00
ENDCHAR
STARTCHAR uni1F57
ENCODING 8023
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
90
90
90
60
00
ENDCHAR
STARTCHAR uni1F59
ENCODING 8025
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
D0
50
20
20
20
00
ENDCHAR
STARTCHAR uni1F5B
ENCODING 8027
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
D0
50
20
20
20
00
ENDCHAR
STARTCHAR uni1F5D
ENCODING 8029
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
D0
50
20
20
20
00
ENDCHAR
STARTCHAR uni1F5F
ENCODING 8031
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
D0
50
20
20
20
00
ENDCHAR
STARTCHAR uni1F60
ENCODING 8032
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
20
90
90
F0
F0
00
ENDCHAR
STARTCHAR uni1F61
ENCODING 8033
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
40
90
90
F0
F0
00
ENDCHAR
STARTCHAR uni1F62
ENCODING 8034
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
50
90
90
F0
F0
00
ENDCHAR
STARTCHAR uni1F63
ENCODING 8035
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
90
90
F0
F0
00
ENDCHAR
STARTCHAR uni1F64
ENCODING 8036
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
60
90
90
F0
F0
00
ENDCHAR
STARTCHAR uni1F65
ENCODING 8037
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
A0
90
90
F0
F0
00
ENDCHAR
STARTCHAR uni1F66
ENCODING 8038
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
90
90
F0
F0
00
ENDCHAR
STARTCHAR uni1F67
ENCODING 8039
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
90
90
F0
F0
00
ENDCHAR
STARTCHAR uni1F68
ENCODING 8040
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
50
20
50
00
ENDCHAR
STARTCHAR uni1F69
ENCODING 8041
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
50
20
50
00
ENDCHAR
STARTCHAR uni1F6A
ENCODING 8042
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
50
20
50
00
ENDCHAR
STARTCHAR uni1F6B
ENCODING 8043
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
50
20
50
00
ENDCHAR
STARTCHAR uni1F6C
ENCODING 8044
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
50
20
50
00
ENDCHAR
STARTCHAR uni1F6D
ENCODING 8045
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
50
20
50
00
ENDCHAR
STARTCHAR uni1F6E
ENCODING 8046
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
50
20
50
00
ENDCHAR
STARTCHAR uni1F6F
ENCODING 8047
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
50
20
50
00
ENDCHAR
STARTCHAR uni1F70
ENCODING 8048
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
20
70
90
B0
50
00
ENDCHAR
STARTCHAR uni1F71
ENCODING 8049
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
20
70
90
B0
50
00
ENDCHAR
STARTCHAR uni1F72
ENCODING 8050
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
20
70
20
40
30
00
ENDCHAR
STARTCHAR uni1F73
ENCODING 8051
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
20
70
20
40
30
00
ENDCHAR
STARTCHAR uni1F74
ENCODING 8052
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
40
E0
90
90
90
10
ENDCHAR
STARTCHAR uni1F75
ENCODING 8053
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
E0
90
90
90
10
ENDCHAR
STARTCHAR uni1F76
ENCODING 8054
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
40
00
40
40
20
00
ENDCHAR
STARTCHAR uni1F77
ENCODING 8055
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
00
40
40
20
00
ENDCHAR
STARTCHAR uni1F78
ENCODING 8056
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
40
60
90
90
60
00
ENDCHAR
STARTCHAR uni1F79
ENCODING 8057
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
60
90
90
60
00
ENDCHAR
STARTCHAR uni1F7A
ENCODING 8058
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
20
90
90
90
60
00
ENDCHAR
STARTCHAR uni1F7B
ENCODING 8059
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
90
90
90
60
00
ENDCHAR
STARTCHAR uni1F7C
ENCODING 8060
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
20
90
90
F0
F0
00
ENDCHAR
STARTCHAR uni1F7D
ENCODING 8061
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
90
90
F0
F0
00
ENDCHAR
STARTCHAR uni1F80
ENCODING 8064
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
20
70
90
B0
50
40
ENDCHAR
STARTCHAR uni1F81
ENCODING 8065
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
40
70
90
B0
50
40
ENDCHAR
STARTCHAR uni1F82
ENCODING 8066
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
50
70
90
B0
50
40
ENDCHAR
STARTCHAR uni1F83
ENCODING 8067
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
70
90
B0
50
40
ENDCHAR
STARTCHAR uni1F84
ENCODING 8068
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
60
70
90
B0
50
40
ENDCHAR
STARTCHAR uni1F85
ENCODING 8069
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
A0
70
90
B0
50
40
ENDCHAR
STARTCHAR uni1F86
ENCODING 8070
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
70
90
B0
50
40
ENDCHAR
STARTCHAR uni1F87
ENCODING 8071
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
70
90
B0
50
40
ENDCHAR
STARTCHAR uni1F88
ENCODING 8072
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
70
50
50
20
ENDCHAR
STARTCHAR uni1F89
ENCODING 8073
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
70
50
50
20
ENDCHAR
STARTCHAR uni1F8A
ENCODING 8074
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
70
50
50
20
ENDCHAR
STARTCHAR uni1F8B
ENCODING 8075
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
70
50
50
20
ENDCHAR
STARTCHAR uni1F8C
ENCODING 8076
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
70
50
50
20
ENDCHAR
STARTCHAR uni1F8D
ENCODING 8077
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
70
50
50
20
ENDCHAR
STARTCHAR uni1F8E
ENCODING 8078
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
70
50
50
20
ENDCHAR
STARTCHAR uni1F8F
ENCODING 8079
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
70
50
50
20
ENDCHAR
STARTCHAR uni1F90
ENCODING 8080
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
20
E0
90
90
10
90
ENDCHAR
STARTCHAR uni1F91
ENCODING 8081
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
40
E0
90
90
10
90
ENDCHAR
STARTCHAR uni1F92
ENCODING 8082
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
50
E0
90
90
10
90
ENDCHAR
STARTCHAR uni1F93
ENCODING 8083
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
E0
90
90
10
90
ENDCHAR
STARTCHAR uni1F94
ENCODING 8084
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
60
E0
90
90
10
90
ENDCHAR
STARTCHAR uni1F95
ENCODING 8085
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
A0
E0
90
90
10
90
ENDCHAR
STARTCHAR uni1F96
ENCODING 8086
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
E0
90
90
10
90
ENDCHAR
STARTCHAR uni1F97
ENCODING 8087
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
E0
90
90
10
90
ENDCHAR
STARTCHAR uni1F98
ENCODING 8088
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
D0
70
50
50
50
20
ENDCHAR
STARTCHAR uni1F99
ENCODING 8089
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
D0
70
50
50
50
20
ENDCHAR
STARTCHAR uni1F9A
ENCODING 8090
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
D0
70
50
50
50
20
ENDCHAR
STARTCHAR uni1F9B
ENCODING 8091
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
D0
70
50
50
50
20
ENDCHAR
STARTCHAR uni1F9C
ENCODING 8092
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
D0
70
50
50
50
20
ENDCHAR
STARTCHAR uni1F9D
ENCODING 8093
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
D0
70
50
50
50
20
ENDCHAR
STARTCHAR uni1F9E
ENCODING 8094
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
D0
70
50
50
50
20
ENDCHAR
STARTCHAR uni1F9F
ENCODING 8095
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
D0
70
50
50
50
20
ENDCHAR
STARTCHAR uni1FA0
ENCODING 8096
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
20
90
90
F0
F0
40
ENDCHAR
STARTCHAR uni1FA1
ENCODING 8097
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
40
90
90
F0
F0
40
ENDCHAR
STARTCHAR uni1FA2
ENCODING 8098
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
50
90
90
F0
F0
40
ENDCHAR
STARTCHAR uni1FA3
ENCODING 8099
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
90
90
F0
F0
40
ENDCHAR
STARTCHAR uni1FA4
ENCODING 8100
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
60
90
90
F0
F0
40
ENDCHAR
STARTCHAR uni1FA5
ENCODING 8101
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
A0
90
90
F0
F0
40
ENDCHAR
STARTCHAR uni1FA6
ENCODING 8102
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
90
90
F0
F0
40
ENDCHAR
STARTCHAR uni1FA7
ENCODING 8103
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
90
90
F0
F0
40
ENDCHAR
STARTCHAR uni1FA8
ENCODING 8104
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
50
20
50
20
ENDCHAR
STARTCHAR uni1FA9
ENCODING 8105
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
50
20
50
20
ENDCHAR
STARTCHAR uni1FAA
ENCODING 8106
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
50
20
50
20
ENDCHAR
STARTCHAR uni1FAB
ENCODING 8107
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
50
20
50
20
ENDCHAR
STARTCHAR uni1FAC
ENCODING 8108
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
50
20
50
20
ENDCHAR
STARTCHAR uni1FAD
ENCODING 8109
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
50
20
50
20
ENDCHAR
STARTCHAR uni1FAE
ENCODING 8110
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
50
20
50
20
ENDCHAR
STARTCHAR uni1FAF
ENCODING 8111
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
50
20
50
20
ENDCHAR
STARTCHAR uni1FB0
ENCODING 8112
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
60
70
90
B0
50
00
ENDCHAR
STARTCHAR uni1FB1
ENCODING 8113
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
00
70
90
B0
50
00
ENDCHAR
STARTCHAR uni1FB2
ENCODING 8114
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
20
70
90
B0
50
40
ENDCHAR
STARTCHAR uni1FB3
ENCODING 8115
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
90
B0
50
40
ENDCHAR
STARTCHAR uni1FB4
ENCODING 8116
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
20
70
90
B0
50
40
ENDCHAR
STARTCHAR uni1FB6
ENCODING 8118
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
00
70
90
B0
50
00
ENDCHAR
STARTCHAR uni1FB7
ENCODING 8119
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
00
70
90
B0
50
40
ENDCHAR
STARTCHAR uni1FB8
ENCODING 8120
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
60
60
90
F0
90
00
ENDCHAR
STARTCHAR uni1FB9
ENCODING 8121
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
00
60
90
F0
90
00
ENDCHAR
STARTCHAR uni1FBA
ENCODING 8122
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
70
50
50
00
ENDCHAR
STARTCHAR uni1FBB
ENCODING 8123
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
70
50
50
00
ENDCHAR
STARTCHAR uni1FBC
ENCODING 8124
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
F0
90
90
40
ENDCHAR
STARTCHAR uni1FBD
ENCODING 8125
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
20
00
00
00
00
00
ENDCHAR
STARTCHAR uni1FBE
ENCODING 8126
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
40
40
20
00
ENDCHAR
STARTCHAR uni1FBF
ENCODING 8127
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
20
00
00
00
00
00
ENDCHAR
STARTCHAR uni1FC0
ENCODING 8128
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
00
00
00
00
00
00
ENDCHAR
STARTCHAR uni1FC1
ENCODING 8129
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
A0
00
00
00
00
00
ENDCHAR
STARTCHAR uni1FC2
ENCODING 8130
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
40
E0
90
90
10
90
ENDCHAR
STARTCHAR uni1FC3
ENCODING 8131
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
E0
90
90
10
90
ENDCHAR
STARTCHAR uni1FC4
ENCODING 8132
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
E0
90
90
10
90
ENDCHAR
STARTCHAR uni1FC6
ENCODING 8134
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
00
E0
90
90
90
10
ENDCHAR
STARTCHAR uni1FC7
ENCODING 8135
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
00
E0
90
90
10
90
ENDCHAR
STARTCHAR uni1FC8
ENCODING 8136
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
C0
60
40
40
70
00
ENDCHAR
STARTCHAR uni1FC9
ENCODING 8137
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
C0
60
40
40
70
00
ENDCHAR
STARTCHAR uni1FCA
ENCODING 8138
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
D0
70
50
50
50
00
ENDCHAR
STARTCHAR uni1FCB
ENCODING 8139
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
D0
70
50
50
50
00
ENDCHAR
STARTCHAR uni1FCC
ENCODING 8140
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
F0
90
90
90
40
ENDCHAR
STARTCHAR uni1FCD
ENCODING 8141
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
50
00
00
00
00
00
ENDCHAR
STARTCHAR uni1FCE
ENCODING 8142
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
60
00
00
00
00
00
ENDCHAR
STARTCHAR uni1FCF
ENCODING 8143
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
40
00
00
00
00
00
ENDCHAR
STARTCHAR uni1FD0
ENCODING 8144
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
60
40
40
40
20
00
ENDCHAR
STARTCHAR uni1FD1
ENCODING 8145
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
00
40
40
40
20
00
ENDCHAR
STARTCHAR uni1FD2
ENCODING 8146
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
20
00
20
20
10
00
ENDCHAR
STARTCHAR uni1FD3
ENCODING 8147
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
B0
40
00
40
40
20
00
ENDCHAR
STARTCHAR uni1FD6
ENCODING 8150
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
00
40
40
40
20
00
ENDCHAR
STARTCHAR uni1FD7
ENCODING 8151
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
A0
00
40
40
20
00
ENDCHAR
STARTCHAR uni1FD8
ENCODING 8152
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
60
70
20
20
70
00
ENDCHAR
STARTCHAR uni1FD9
ENCODING 8153
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
00
70
20
20
70
00
ENDCHAR
STARTCHAR uni1FDA
ENCODING 8154
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
A0
20
20
20
70
00
ENDCHAR
STARTCHAR uni1FDB
ENCODING 8155
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
A0
20
20
20
70
00
ENDCHAR
STARTCHAR uni1FDD
ENCODING 8157
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
90
00
00
00
00
00
ENDCHAR
STARTCHAR uni1FDE
ENCODING 8158
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
A0
00
00
00
00
00
ENDCHAR
STARTCHAR uni1FDF
ENCODING 8159
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
40
00
00
00
00
00
ENDCHAR
STARTCHAR uni1FE0
ENCODING 8160
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
60
90
90
90
60
00
ENDCHAR
STARTCHAR uni1FE1
ENCODING 8161
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
00
90
90
90
60
00
ENDCHAR
STARTCHAR uni1FE2
ENCODING 8162
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
20
90
90
90
60
00
ENDCHAR
STARTCHAR uni1FE3
ENCODING 8163
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
B0
40
90
90
90
60
00
ENDCHAR
STARTCHAR uni1FE4
ENCODING 8164
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
20
60
90
90
E0
80
ENDCHAR
STARTCHAR uni1FE5
ENCODING 8165
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
40
60
90
90
E0
80
ENDCHAR
STARTCHAR uni1FE6
ENCODING 8166
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
00
90
90
90
60
00
ENDCHAR
STARTCHAR uni1FE7
ENCODING 8167
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
90
00
90
90
60
00
ENDCHAR
STARTCHAR uni1FE8
ENCODING 8168
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
60
A0
A0
40
40
00
ENDCHAR
STARTCHAR uni1FE9
ENCODING 8169
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
00
A0
A0
40
40
00
ENDCHAR
STARTCHAR uni1FEA
ENCODING 8170
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
D0
50
20
20
20
00
ENDCHAR
STARTCHAR uni1FEB
ENCODING 8171
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
D0
50
20
20
20
00
ENDCHAR
STARTCHAR uni1FEC
ENCODING 8172
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
D0
50
60
40
40
00
ENDCHAR
STARTCHAR uni1FED
ENCODING 8173
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D0
20
00
00
00
00
00
ENDCHAR
STARTCHAR uni1FEE
ENCODING 8174
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
B0
40
00
00
00
00
00
ENDCHAR
STARTCHAR uni1FEF
ENCODING 8175
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
20
00
00
00
00
00
ENDCHAR
STARTCHAR uni1FF2
ENCODING 8178
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
20
90
90
F0
F0
40
ENDCHAR
STARTCHAR uni1FF3
ENCODING 8179
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
90
F0
F0
40
ENDCHAR
STARTCHAR uni1FF4
ENCODING 8180
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
90
90
F0
F0
40
ENDCHAR
STARTCHAR uni1FF6
ENCODING 8182
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
00
90
90
F0
F0
00
ENDCHAR
STARTCHAR uni1FF7
ENCODING 8183
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
00
90
90
F0
F0
40
ENDCHAR
STARTCHAR uni1FF8
ENCODING 8184
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
50
50
20
00
ENDCHAR
STARTCHAR uni1FF9
ENCODING 8185
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
50
50
20
00
ENDCHAR
STARTCHAR uni1FFA
ENCODING 8186
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
50
20
50
00
ENDCHAR
STARTCHAR uni1FFB
ENCODING 8187
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
50
50
20
50
00
ENDCHAR
STARTCHAR uni1FFC
ENCODING 8188
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
50
50
50
20
50
20
ENDCHAR
STARTCHAR uni1FFD
ENCODING 8189
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
00
00
00
00
00
ENDCHAR
STARTCHAR uni1FFE
ENCODING 8190
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
40
00
00
00
00
00
ENDCHAR
STARTCHAR uni2010
ENCODING 8208
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
70
00
00
00
ENDCHAR
STARTCHAR uni2011
ENCODING 8209
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
70
00
00
00
ENDCHAR
STARTCHAR figuredash
ENCODING 8210
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
F0
00
00
00
ENDCHAR
STARTCHAR endash
ENCODING 8211
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
F0
00
00
00
ENDCHAR
STARTCHAR emdash
ENCODING 8212
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
F8
00
00
00
ENDCHAR
STARTCHAR afii00208
ENCODING 8213
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
F8
00
00
00
ENDCHAR
STARTCHAR uni2016
ENCODING 8214
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
50
50
50
50
00
ENDCHAR
STARTCHAR underscoredbl
ENCODING 8215
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
F0
00
F0
ENDCHAR
STARTCHAR quoteleft
ENCODING 8216
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
60
00
00
00
00
ENDCHAR
STARTCHAR quoteright
ENCODING 8217
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
20
40
00
00
00
00
ENDCHAR
STARTCHAR quotesinglbase
ENCODING 8218
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
60
20
40
ENDCHAR
STARTCHAR quotereversed
ENCODING 8219
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
40
20
00
00
00
00
ENDCHAR
STARTCHAR quotedblleft
ENCODING 8220
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
A0
A0
00
00
00
00
ENDCHAR
STARTCHAR quotedblright
ENCODING 8221
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
A0
00
00
00
00
ENDCHAR
STARTCHAR quotedblbase
ENCODING 8222
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
50
50
A0
ENDCHAR
STARTCHAR uni201F
ENCODING 8223
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
A0
50
00
00
00
00
ENDCHAR
STARTCHAR dagger
ENCODING 8224
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
20
70
20
20
20
00
ENDCHAR
STARTCHAR daggerdbl
ENCODING 8225
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
20
70
20
70
20
00
ENDCHAR
STARTCHAR bullet
ENCODING 8226
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
F0
F0
60
00
ENDCHAR
STARTCHAR uni2023
ENCODING 8227
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
40
60
70
60
40
00
ENDCHAR
STARTCHAR onedotenleader
ENCODING 8228
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
00
20
00
ENDCHAR
STARTCHAR twodotenleader
ENCODING 8229
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
00
50
00
ENDCHAR
STARTCHAR ellipsis
ENCODING 8230
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
00
A8
00
ENDCHAR
STARTCHAR uni2027
ENCODING 8231
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
60
00
00
00
ENDCHAR
STARTCHAR perthousand
ENCODING 8240
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
90
20
40
A8
28
00
ENDCHAR
STARTCHAR minute
ENCODING 8242
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
40
00
00
00
00
ENDCHAR
STARTCHAR second
ENCODING 8243
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
A0
00
00
00
00
ENDCHAR
STARTCHAR uni2034
ENCODING 8244
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
70
E0
00
00
00
00
ENDCHAR
STARTCHAR uni2035
ENCODING 8245
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
40
20
00
00
00
00
ENDCHAR
STARTCHAR uni2036
ENCODING 8246
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
A0
50
00
00
00
00
ENDCHAR
STARTCHAR uni2037
ENCODING 8247
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
E0
70
00
00
00
00
ENDCHAR
STARTCHAR guilsinglleft
ENCODING 8249
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
20
40
20
00
00
ENDCHAR
STARTCHAR guilsinglright
ENCODING 8250
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
40
20
40
00
00
ENDCHAR
STARTCHAR exclamdbl
ENCODING 8252
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
50
50
00
50
00
ENDCHAR
STARTCHAR uni203E
ENCODING 8254
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F8
00
00
00
00
00
00
ENDCHAR
STARTCHAR fraction
ENCODING 8260
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
10
20
40
80
00
00
ENDCHAR
STARTCHAR zerosuperior
ENCODING 8304
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
50
50
20
00
00
00
ENDCHAR
STARTCHAR uni2071
ENCODING 8305
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
00
20
20
00
00
00
ENDCHAR
STARTCHAR foursuperior
ENCODING 8308
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
60
70
20
00
00
00
ENDCHAR
STARTCHAR fivesuperior
ENCODING 8309
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
60
10
60
00
00
00
ENDCHAR
STARTCHAR sixsuperior
ENCODING 8310
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
60
50
20
00
00
00
ENDCHAR
STARTCHAR sevensuperior
ENCODING 8311
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
10
20
20
00
00
00
ENDCHAR
STARTCHAR eightsuperior
ENCODING 8312
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
50
20
50
20
00
00
ENDCHAR
STARTCHAR ninesuperior
ENCODING 8313
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
50
30
60
00
00
00
ENDCHAR
STARTCHAR uni207A
ENCODING 8314
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
20
70
20
00
00
00
ENDCHAR
STARTCHAR uni207B
ENCODING 8315
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
00
00
00
00
ENDCHAR
STARTCHAR uni207C
ENCODING 8316
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
70
00
70
00
00
00
ENDCHAR
STARTCHAR parenleftsuperior
ENCODING 8317
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
40
40
20
00
00
00
ENDCHAR
STARTCHAR parenrightsuperior
ENCODING 8318
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
10
10
20
00
00
00
ENDCHAR
STARTCHAR nsuperior
ENCODING 8319
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
60
50
50
00
00
00
ENDCHAR
STARTCHAR zeroinferior
ENCODING 8320
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
20
50
50
20
ENDCHAR
STARTCHAR oneinferior
ENCODING 8321
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
20
60
20
70
ENDCHAR
STARTCHAR twoinferior
ENCODING 8322
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
60
20
40
60
ENDCHAR
STARTCHAR threeinferior
ENCODING 8323
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
60
60
20
60
ENDCHAR
STARTCHAR fourinferior
ENCODING 8324
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
20
60
70
20
ENDCHAR
STARTCHAR fiveinferior
ENCODING 8325
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
70
60
10
60
ENDCHAR
STARTCHAR sixinferior
ENCODING 8326
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
30
60
50
20
ENDCHAR
STARTCHAR seveninferior
ENCODING 8327
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
70
10
20
20
ENDCHAR
STARTCHAR eightinferior
ENCODING 8328
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
20
50
20
50
20
ENDCHAR
STARTCHAR nineinferior
ENCODING 8329
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
20
50
30
60
ENDCHAR
STARTCHAR uni208A
ENCODING 8330
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
20
70
20
ENDCHAR
STARTCHAR uni208B
ENCODING 8331
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
00
70
00
ENDCHAR
STARTCHAR uni208C
ENCODING 8332
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
70
00
70
ENDCHAR
STARTCHAR parenleftinferior
ENCODING 8333
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
20
40
40
20
ENDCHAR
STARTCHAR parenrightinferior
ENCODING 8334
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
20
10
10
20
ENDCHAR
STARTCHAR franc
ENCODING 8355
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
80
D8
A0
A0
A0
00
ENDCHAR
STARTCHAR lira
ENCODING 8356
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
40
E0
E0
40
B0
00
ENDCHAR
STARTCHAR peseta
ENCODING 8359
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
50
F8
70
40
40
00
ENDCHAR
STARTCHAR dong
ENCODING 8363
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
38
70
90
90
70
F0
ENDCHAR
STARTCHAR Euro
ENCODING 8364
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
40
E0
E0
40
30
00
ENDCHAR
STARTCHAR uni20AF
ENCODING 8367
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
60
D0
50
D0
E0
00
ENDCHAR
STARTCHAR uni20D0
ENCODING 8400
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
F8
00
00
00
00
00
ENDCHAR
STARTCHAR uni20D1
ENCODING 8401
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
F8
00
00
00
00
00
ENDCHAR
STARTCHAR uni20D2
ENCODING 8402
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
20
20
20
20
20
ENDCHAR
STARTCHAR uni20D3
ENCODING 8403
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
20
20
20
20
20
20
ENDCHAR
STARTCHAR uni20D4
ENCODING 8404
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
D0
D0
00
00
00
00
ENDCHAR
STARTCHAR uni20D5
ENCODING 8405
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
B0
B0
00
00
00
00
ENDCHAR
STARTCHAR uni20D6
ENCODING 8406
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
F8
40
00
00
00
00
ENDCHAR
STARTCHAR uni20D7
ENCODING 8407
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
F8
10
00
00
00
00
ENDCHAR
STARTCHAR uni2102
ENCODING 8450
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
D0
C0
C0
D0
60
00
ENDCHAR
STARTCHAR afii61248
ENCODING 8453
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
80
70
60
A0
50
20
ENDCHAR
STARTCHAR afii61289
ENCODING 8467
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
30
30
20
20
50
00
ENDCHAR
STARTCHAR uni2115
ENCODING 8469
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
C8
C8
E8
D8
C8
C8
00
ENDCHAR
STARTCHAR afii61352
ENCODING 8470
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
C0
A0
A0
B0
A8
B0
00
ENDCHAR
STARTCHAR uni211A
ENCODING 8474
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
D0
D0
D0
F0
70
10
ENDCHAR
STARTCHAR uni211D
ENCODING 8477
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
D0
D0
F0
E0
D0
00
ENDCHAR
STARTCHAR trademark
ENCODING 8482
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
20
00
F8
A8
A8
ENDCHAR
STARTCHAR uni2124
ENCODING 8484
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
30
60
60
C0
F0
00
ENDCHAR
STARTCHAR Omega
ENCODING 8486
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
50
50
50
20
70
00
ENDCHAR
STARTCHAR uni2127
ENCODING 8487
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
50
50
50
20
00
ENDCHAR
STARTCHAR estimated
ENCODING 8494
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
D8
E0
70
00
ENDCHAR
STARTCHAR oneeighth
ENCODING 8539
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
80
80
B0
30
30
30
ENDCHAR
STARTCHAR threeeighths
ENCODING 8540
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
C0
C0
40
F0
30
30
30
ENDCHAR
STARTCHAR fiveeighths
ENCODING 8541
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
C0
80
40
B0
30
30
30
ENDCHAR
STARTCHAR seveneighths
ENCODING 8542
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
C0
40
80
B0
30
30
30
ENDCHAR
STARTCHAR arrowleft
ENCODING 8592
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
40
F0
40
00
00
ENDCHAR
STARTCHAR arrowup
ENCODING 8593
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
70
20
20
20
20
00
ENDCHAR
STARTCHAR arrowright
ENCODING 8594
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
20
F0
20
00
00
ENDCHAR
STARTCHAR arrowdown
ENCODING 8595
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
20
20
70
20
00
ENDCHAR
STARTCHAR arrowboth
ENCODING 8596
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
F8
50
00
00
ENDCHAR
STARTCHAR arrowupdn
ENCODING 8597
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
70
20
20
70
20
00
ENDCHAR
STARTCHAR uni21A4
ENCODING 8612
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
F0
50
00
00
ENDCHAR
STARTCHAR uni21A5
ENCODING 8613
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
70
20
20
20
70
00
ENDCHAR
STARTCHAR uni21A6
ENCODING 8614
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
A0
F0
A0
00
00
ENDCHAR
STARTCHAR uni21A7
ENCODING 8615
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
20
20
70
20
00
ENDCHAR
STARTCHAR arrowupdnbse
ENCODING 8616
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
70
20
20
70
20
70
ENDCHAR
STARTCHAR uni21C4
ENCODING 8644
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
F8
10
40
F8
40
00
ENDCHAR
STARTCHAR uni21C6
ENCODING 8646
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
F8
40
10
F8
10
00
ENDCHAR
STARTCHAR uni21CB
ENCODING 8651
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
40
F0
00
F0
20
00
ENDCHAR
STARTCHAR uni21CC
ENCODING 8652
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
20
F0
00
F0
40
00
ENDCHAR
STARTCHAR arrowdblleft
ENCODING 8656
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
20
78
80
78
20
10
ENDCHAR
STARTCHAR arrowdblup
ENCODING 8657
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
50
D8
50
50
50
00
ENDCHAR
STARTCHAR arrowdblright
ENCODING 8658
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
20
F0
08
F0
20
40
ENDCHAR
STARTCHAR arrowdbldown
ENCODING 8659
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
50
D8
50
20
00
ENDCHAR
STARTCHAR arrowdblboth
ENCODING 8660
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
20
70
88
70
20
00
ENDCHAR
STARTCHAR uni21D5
ENCODING 8661
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
50
D8
50
D8
50
20
ENDCHAR
STARTCHAR universal
ENCODING 8704
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
F0
90
90
60
00
ENDCHAR
STARTCHAR uni2201
ENCODING 8705
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
50
40
40
50
20
00
ENDCHAR
STARTCHAR partialdiff
ENCODING 8706
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
10
30
50
50
20
00
ENDCHAR
STARTCHAR existential
ENCODING 8707
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
10
70
10
10
F0
00
ENDCHAR
STARTCHAR uni2204
ENCODING 8708
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
F0
50
70
50
F0
40
ENDCHAR
STARTCHAR emptyset
ENCODING 8709
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
70
B0
D0
D0
E0
80
ENDCHAR
STARTCHAR Delta
ENCODING 8710
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
50
50
88
F8
00
ENDCHAR
STARTCHAR gradient
ENCODING 8711
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F8
88
50
50
20
20
00
ENDCHAR
STARTCHAR element
ENCODING 8712
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
70
80
F0
80
70
00
ENDCHAR
STARTCHAR notelement
ENCODING 8713
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
70
A0
F0
A0
70
40
ENDCHAR
STARTCHAR uni220A
ENCODING 8714
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
30
40
70
40
30
00
ENDCHAR
STARTCHAR suchthat
ENCODING 8715
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
E0
10
F0
10
E0
00
ENDCHAR
STARTCHAR uni220C
ENCODING 8716
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
E0
50
F0
50
E0
80
ENDCHAR
STARTCHAR uni220D
ENCODING 8717
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
60
10
70
10
60
00
ENDCHAR
STARTCHAR uni220E
ENCODING 8718
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
F0
F0
F0
F0
F0
00
ENDCHAR
STARTCHAR product
ENCODING 8719
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F8
50
50
50
50
D8
00
ENDCHAR
STARTCHAR uni2210
ENCODING 8720
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
D8
50
50
50
50
F8
00
ENDCHAR
STARTCHAR summation
ENCODING 8721
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
40
20
40
80
F0
00
ENDCHAR
STARTCHAR minus
ENCODING 8722
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
F8
00
00
00
ENDCHAR
STARTCHAR uni2213
ENCODING 8723
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F8
20
20
F8
20
20
00
ENDCHAR
STARTCHAR uni2214
ENCODING 8724
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
00
20
20
F8
20
20
ENDCHAR
STARTCHAR fraction
ENCODING 8725
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
10
20
40
80
80
00
ENDCHAR
STARTCHAR uni2216
ENCODING 8726
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
80
40
20
10
00
ENDCHAR
STARTCHAR asteriskmath
ENCODING 8727
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
20
A8
70
A8
20
00
ENDCHAR
STARTCHAR uni2218
ENCODING 8728
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
20
50
20
00
00
ENDCHAR
STARTCHAR periodcentered
ENCODING 8729
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
20
70
20
00
00
ENDCHAR
STARTCHAR radical
ENCODING 8730
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
08
10
10
20
A0
40
00
ENDCHAR
STARTCHAR uni221B
ENCODING 8731
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
88
D0
90
20
A0
40
00
ENDCHAR
STARTCHAR uni221C
ENCODING 8732
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
88
D0
50
20
A0
40
00
ENDCHAR
STARTCHAR proportional
ENCODING 8733
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
A0
A0
50
00
ENDCHAR
STARTCHAR infinity
ENCODING 8734
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
A8
A8
50
00
ENDCHAR
STARTCHAR orthogonal
ENCODING 8735
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
80
80
80
F0
00
ENDCHAR
STARTCHAR angle
ENCODING 8736
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
10
20
40
F0
00
ENDCHAR
STARTCHAR uni2221
ENCODING 8737
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
10
A0
40
F0
20
ENDCHAR
STARTCHAR uni2222
ENCODING 8738
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
50
60
A0
60
50
00
ENDCHAR
STARTCHAR uni2223
ENCODING 8739
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
20
20
20
20
00
ENDCHAR
STARTCHAR uni2224
ENCODING 8740
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
30
60
20
20
00
ENDCHAR
STARTCHAR uni2225
ENCODING 8741
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
50
50
50
50
00
ENDCHAR
STARTCHAR uni2226
ENCODING 8742
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
58
70
70
D0
50
00
ENDCHAR
STARTCHAR logicaland
ENCODING 8743
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
20
20
50
50
00
ENDCHAR
STARTCHAR logicalor
ENCODING 8744
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
50
20
20
00
ENDCHAR
STARTCHAR intersection
ENCODING 8745
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
90
90
90
00
ENDCHAR
STARTCHAR union
ENCODING 8746
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
90
90
60
00
ENDCHAR
STARTCHAR integral
ENCODING 8747
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
28
20
20
20
A0
40
ENDCHAR
STARTCHAR uni222C
ENCODING 8748
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
28
50
50
50
50
50
A0
ENDCHAR
STARTCHAR uni222D
ENCODING 8749
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
38
70
70
70
70
70
E0
ENDCHAR
STARTCHAR uni222E
ENCODING 8750
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
28
70
A8
70
A0
40
ENDCHAR
STARTCHAR uni222F
ENCODING 8751
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
28
50
70
D8
70
50
A0
ENDCHAR
STARTCHAR uni2230
ENCODING 8752
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
38
70
70
F8
70
70
E0
ENDCHAR
STARTCHAR therefore
ENCODING 8756
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
20
00
50
00
00
ENDCHAR
STARTCHAR uni2235
ENCODING 8757
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
00
20
00
00
ENDCHAR
STARTCHAR uni2236
ENCODING 8758
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
20
00
00
20
00
ENDCHAR
STARTCHAR uni2237
ENCODING 8759
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
90
00
00
90
00
ENDCHAR
STARTCHAR uni2238
ENCODING 8760
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
20
00
F8
00
00
ENDCHAR
STARTCHAR uni2239
ENCODING 8761
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
10
C0
10
00
00
ENDCHAR
STARTCHAR uni223A
ENCODING 8762
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
90
00
F0
00
90
00
ENDCHAR
STARTCHAR similar
ENCODING 8764
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
50
A0
00
00
ENDCHAR
STARTCHAR uni2243
ENCODING 8771
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
50
A0
00
F0
00
00
ENDCHAR
STARTCHAR congruent
ENCODING 8773
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
A0
00
F0
00
F0
00
ENDCHAR
STARTCHAR approxequal
ENCODING 8776
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
50
A0
00
50
A0
00
ENDCHAR
STARTCHAR uni2249
ENCODING 8777
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
50
A0
20
50
A0
80
ENDCHAR
STARTCHAR uni2259
ENCODING 8793
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
50
00
F0
00
F0
00
ENDCHAR
STARTCHAR uni225A
ENCODING 8794
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
20
00
F0
00
F0
00
ENDCHAR
STARTCHAR uni225F
ENCODING 8799
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
20
00
20
F0
00
F0
ENDCHAR
STARTCHAR notequal
ENCODING 8800
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
10
F0
20
F0
40
00
ENDCHAR
STARTCHAR equivalence
ENCODING 8801
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
F0
00
F0
00
F0
00
ENDCHAR
STARTCHAR uni2262
ENCODING 8802
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
F0
20
F0
20
F0
40
ENDCHAR
STARTCHAR uni2263
ENCODING 8803
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
00
F0
00
F0
00
F0
ENDCHAR
STARTCHAR lessequal
ENCODING 8804
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
20
40
20
10
70
00
ENDCHAR
STARTCHAR greaterequal
ENCODING 8805
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
20
10
20
40
70
00
ENDCHAR
STARTCHAR uni226A
ENCODING 8810
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
28
50
A0
50
28
00
ENDCHAR
STARTCHAR uni226B
ENCODING 8811
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
A0
50
28
50
A0
00
ENDCHAR
STARTCHAR propersubset
ENCODING 8834
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
80
80
70
00
ENDCHAR
STARTCHAR propersuperset
ENCODING 8835
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
E0
10
10
E0
00
ENDCHAR
STARTCHAR notsubset
ENCODING 8836
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
20
70
A0
A0
70
20
ENDCHAR
STARTCHAR uni2285
ENCODING 8837
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
40
E0
50
50
E0
40
ENDCHAR
STARTCHAR reflexsubset
ENCODING 8838
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
70
80
70
00
F0
00
ENDCHAR
STARTCHAR reflexsuperset
ENCODING 8839
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
E0
10
E0
00
F0
00
ENDCHAR
STARTCHAR uni2288
ENCODING 8840
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
70
A0
70
20
F0
20
ENDCHAR
STARTCHAR uni2289
ENCODING 8841
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
E0
50
E0
40
F0
40
ENDCHAR
STARTCHAR uni228A
ENCODING 8842
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
70
80
70
20
F0
20
ENDCHAR
STARTCHAR uni228B
ENCODING 8843
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
E0
10
E0
40
F0
40
ENDCHAR
STARTCHAR circleplus
ENCODING 8853
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
70
A8
F8
A8
70
00
ENDCHAR
STARTCHAR uni2296
ENCODING 8854
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
70
88
F8
88
70
00
ENDCHAR
STARTCHAR circlemultiply
ENCODING 8855
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
70
D8
A8
D8
70
00
ENDCHAR
STARTCHAR uni2298
ENCODING 8856
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
70
98
A8
C8
70
00
ENDCHAR
STARTCHAR uni2299
ENCODING 8857
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
70
88
A8
88
70
00
ENDCHAR
STARTCHAR uni22A2
ENCODING 8866
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
80
80
F0
80
80
00
ENDCHAR
STARTCHAR uni22A3
ENCODING 8867
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
10
10
F0
10
10
00
ENDCHAR
STARTCHAR uni22A4
ENCODING 8868
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
20
20
20
20
20
00
ENDCHAR
STARTCHAR perpendicular
ENCODING 8869
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
20
20
20
70
00
ENDCHAR
STARTCHAR uni22A6
ENCODING 8870
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
40
40
70
40
40
00
ENDCHAR
STARTCHAR uni22A7
ENCODING 8871
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
40
70
40
70
40
00
ENDCHAR
STARTCHAR uni22A8
ENCODING 8872
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
80
F0
80
F0
80
00
ENDCHAR
STARTCHAR uni22C2
ENCODING 8898
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
90
90
90
90
90
00
ENDCHAR
STARTCHAR uni22C3
ENCODING 8899
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
90
90
90
90
90
60
00
ENDCHAR
STARTCHAR dotmath
ENCODING 8901
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
20
00
00
00
ENDCHAR
STARTCHAR uni22EE
ENCODING 8942
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
20
00
20
00
20
00
ENDCHAR
STARTCHAR uni22EF
ENCODING 8943
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
A8
00
00
00
ENDCHAR
STARTCHAR uni22F0
ENCODING 8944
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
08
00
20
00
80
00
ENDCHAR
STARTCHAR uni22F1
ENCODING 8945
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
80
00
20
00
08
00
ENDCHAR
STARTCHAR uni2300
ENCODING 8960
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
78
98
A8
C8
F0
00
ENDCHAR
STARTCHAR house
ENCODING 8962
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
20
50
88
88
F8
00
ENDCHAR
STARTCHAR uni2308
ENCODING 8968
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
40
40
40
40
40
00
ENDCHAR
STARTCHAR uni2309
ENCODING 8969
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
10
10
10
10
10
00
ENDCHAR
STARTCHAR uni230A
ENCODING 8970
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
40
40
40
40
70
00
ENDCHAR
STARTCHAR uni230B
ENCODING 8971
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
10
10
10
10
70
00
ENDCHAR
STARTCHAR revlogicalnot
ENCODING 8976
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
F0
80
00
00
ENDCHAR
STARTCHAR integraltp
ENCODING 8992
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
28
20
20
20
20
20
ENDCHAR
STARTCHAR integralbt
ENCODING 8993
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
20
20
20
A0
40
ENDCHAR
STARTCHAR angleleft
ENCODING 9001
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
40
40
20
20
00
ENDCHAR
STARTCHAR angleright
ENCODING 9002
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
40
20
20
40
40
00
ENDCHAR
STARTCHAR uni23BA
ENCODING 9146
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F8
00
00
00
00
00
00
ENDCHAR
STARTCHAR uni23BB
ENCODING 9147
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
F8
00
00
00
00
00
ENDCHAR
STARTCHAR uni23BC
ENCODING 9148
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
00
F8
00
ENDCHAR
STARTCHAR uni23BD
ENCODING 9149
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
00
00
F8
ENDCHAR
STARTCHAR uni2409
ENCODING 9225
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
E0
A0
70
20
20
00
ENDCHAR
STARTCHAR uni240A
ENCODING 9226
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
80
F0
20
30
20
00
ENDCHAR
STARTCHAR uni240B
ENCODING 9227
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A0
A0
78
50
10
10
00
ENDCHAR
STARTCHAR uni240C
ENCODING 9228
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
80
F8
A0
30
20
00
ENDCHAR
STARTCHAR uni240D
ENCODING 9229
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
80
E0
50
60
50
00
ENDCHAR
STARTCHAR uni2423
ENCODING 9251
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
90
F0
00
ENDCHAR
STARTCHAR uni2424
ENCODING 9252
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
C0
A0
A0
A0
20
38
00
ENDCHAR
STARTCHAR SF100000
ENCODING 9472
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
F8
00
00
00
ENDCHAR
STARTCHAR uni2501
ENCODING 9473
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F8
F8
00
00
00
ENDCHAR
STARTCHAR SF110000
ENCODING 9474
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
20
20
20
20
20
ENDCHAR
STARTCHAR uni2503
ENCODING 9475
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
30
30
30
30
30
30
ENDCHAR
STARTCHAR uni2504
ENCODING 9476
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
A8
00
00
00
ENDCHAR
STARTCHAR uni2505
ENCODING 9477
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
A8
A8
00
00
00
ENDCHAR
STARTCHAR uni2506
ENCODING 9478
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
00
20
20
00
20
00
ENDCHAR
STARTCHAR uni2507
ENCODING 9479
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
00
30
30
00
30
00
ENDCHAR
STARTCHAR uni2508
ENCODING 9480
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
A8
00
00
00
ENDCHAR
STARTCHAR uni2509
ENCODING 9481
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
A8
A8
00
00
00
ENDCHAR
STARTCHAR uni250A
ENCODING 9482
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
00
20
00
20
00
20
ENDCHAR
STARTCHAR uni250B
ENCODING 9483
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
00
30
00
30
00
30
ENDCHAR
STARTCHAR SF010000
ENCODING 9484
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
38
20
20
20
ENDCHAR
STARTCHAR uni250D
ENCODING 9485
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
38
38
20
20
20
ENDCHAR
STARTCHAR uni250E
ENCODING 9486
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
38
30
30
30
ENDCHAR
STARTCHAR uni250F
ENCODING 9487
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
38
38
30
30
30
ENDCHAR
STARTCHAR SF030000
ENCODING 9488
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
E0
20
20
20
ENDCHAR
STARTCHAR uni2511
ENCODING 9489
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
E0
E0
20
20
20
ENDCHAR
STARTCHAR uni2512
ENCODING 9490
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
F0
30
30
30
ENDCHAR
STARTCHAR uni2513
ENCODING 9491
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F0
F0
30
30
30
ENDCHAR
STARTCHAR SF020000
ENCODING 9492
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
20
38
00
00
00
ENDCHAR
STARTCHAR uni2515
ENCODING 9493
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
38
38
00
00
00
ENDCHAR
STARTCHAR uni2516
ENCODING 9494
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
30
30
38
00
00
00
ENDCHAR
STARTCHAR uni2517
ENCODING 9495
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
30
38
38
00
00
00
ENDCHAR
STARTCHAR SF040000
ENCODING 9496
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
20
E0
00
00
00
ENDCHAR
STARTCHAR uni2519
ENCODING 9497
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
E0
E0
00
00
00
ENDCHAR
STARTCHAR uni251A
ENCODING 9498
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
30
30
F0
00
00
00
ENDCHAR
STARTCHAR uni251B
ENCODING 9499
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
30
F0
F0
00
00
00
ENDCHAR
STARTCHAR SF080000
ENCODING 9500
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
20
38
20
20
20
ENDCHAR
STARTCHAR uni251D
ENCODING 9501
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
38
38
20
20
20
ENDCHAR
STARTCHAR uni251E
ENCODING 9502
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
30
30
38
20
20
20
ENDCHAR
STARTCHAR uni251F
ENCODING 9503
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
20
38
30
30
30
ENDCHAR
STARTCHAR uni2520
ENCODING 9504
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
30
30
38
30
30
30
ENDCHAR
STARTCHAR uni2521
ENCODING 9505
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
30
38
38
20
20
20
ENDCHAR
STARTCHAR uni2522
ENCODING 9506
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
38
38
30
30
30
ENDCHAR
STARTCHAR uni2523
ENCODING 9507
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
30
38
38
30
30
30
ENDCHAR
STARTCHAR SF090000
ENCODING 9508
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
20
E0
20
20
20
ENDCHAR
STARTCHAR uni2525
ENCODING 9509
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
E0
E0
20
20
20
ENDCHAR
STARTCHAR uni2526
ENCODING 9510
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
30
30
F0
20
20
20
ENDCHAR
STARTCHAR uni2527
ENCODING 9511
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
20
F0
30
30
30
ENDCHAR
STARTCHAR uni2528
ENCODING 9512
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
30
30
F0
30
30
30
ENDCHAR
STARTCHAR uni2529
ENCODING 9513
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
30
F0
F0
20
20
20
ENDCHAR
STARTCHAR uni252A
ENCODING 9514
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
F0
F0
30
30
30
ENDCHAR
STARTCHAR uni252B
ENCODING 9515
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
30
F0
F0
30
30
30
ENDCHAR
STARTCHAR SF060000
ENCODING 9516
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
F8
20
20
20
ENDCHAR
STARTCHAR uni252D
ENCODING 9517
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
E0
F8
20
20
20
ENDCHAR
STARTCHAR uni252E
ENCODING 9518
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
38
F8
20
20
20
ENDCHAR
STARTCHAR uni252F
ENCODING 9519
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F8
F8
20
20
20
ENDCHAR
STARTCHAR uni2530
ENCODING 9520
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
F8
30
30
30
ENDCHAR
STARTCHAR uni2531
ENCODING 9521
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
E0
F8
30
30
30
ENDCHAR
STARTCHAR uni2532
ENCODING 9522
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
18
F8
30
30
30
ENDCHAR
STARTCHAR uni2533
ENCODING 9523
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F8
F8
30
30
30
ENDCHAR
STARTCHAR SF070000
ENCODING 9524
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
20
F8
00
00
00
ENDCHAR
STARTCHAR uni2535
ENCODING 9525
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
E0
F8
00
00
00
ENDCHAR
STARTCHAR uni2536
ENCODING 9526
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
38
F8
00
00
00
ENDCHAR
STARTCHAR uni2537
ENCODING 9527
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
F8
F8
00
00
00
ENDCHAR
STARTCHAR uni2538
ENCODING 9528
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
30
30
F8
00
00
00
ENDCHAR
STARTCHAR uni2539
ENCODING 9529
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
30
F0
F8
00
00
00
ENDCHAR
STARTCHAR uni253A
ENCODING 9530
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
30
38
F8
00
00
00
ENDCHAR
STARTCHAR uni253B
ENCODING 9531
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
30
F8
F8
00
00
00
ENDCHAR
STARTCHAR SF050000
ENCODING 9532
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
20
F8
20
20
20
ENDCHAR
STARTCHAR uni253D
ENCODING 9533
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
E0
F8
20
20
20
ENDCHAR
STARTCHAR uni253E
ENCODING 9534
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
38
F8
20
20
20
ENDCHAR
STARTCHAR uni253F
ENCODING 9535
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
F8
F8
20
20
20
ENDCHAR
STARTCHAR uni2540
ENCODING 9536
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
30
30
F8
20
20
20
ENDCHAR
STARTCHAR uni2541
ENCODING 9537
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
20
F8
30
30
30
ENDCHAR
STARTCHAR uni2542
ENCODING 9538
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
30
30
F8
30
30
30
ENDCHAR
STARTCHAR uni2543
ENCODING 9539
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
30
F0
F8
20
20
20
ENDCHAR
STARTCHAR uni2544
ENCODING 9540
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
30
38
F8
20
20
20
ENDCHAR
STARTCHAR uni2545
ENCODING 9541
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
E0
F8
30
30
30
ENDCHAR
STARTCHAR uni2546
ENCODING 9542
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
38
F8
30
30
30
ENDCHAR
STARTCHAR uni2547
ENCODING 9543
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
30
F8
F8
20
20
20
ENDCHAR
STARTCHAR uni2548
ENCODING 9544
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
F8
F8
30
30
30
ENDCHAR
STARTCHAR uni2549
ENCODING 9545
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
30
F0
F8
30
30
30
ENDCHAR
STARTCHAR uni254A
ENCODING 9546
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
30
38
F8
30
30
30
ENDCHAR
STARTCHAR uni254B
ENCODING 9547
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
30
F8
F8
30
30
30
ENDCHAR
STARTCHAR uni254C
ENCODING 9548
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
D0
00
00
00
ENDCHAR
STARTCHAR uni254D
ENCODING 9549
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
D0
D0
00
00
00
ENDCHAR
STARTCHAR uni254E
ENCODING 9550
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
20
00
20
20
00
ENDCHAR
STARTCHAR uni254F
ENCODING 9551
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
30
30
00
30
30
00
ENDCHAR
STARTCHAR SF430000
ENCODING 9552
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F8
00
F8
00
00
ENDCHAR
STARTCHAR SF240000
ENCODING 9553
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
50
50
50
50
50
ENDCHAR
STARTCHAR SF510000
ENCODING 9554
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
38
20
38
20
20
ENDCHAR
STARTCHAR SF520000
ENCODING 9555
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
78
50
50
50
ENDCHAR
STARTCHAR SF390000
ENCODING 9556
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
78
40
58
50
50
ENDCHAR
STARTCHAR SF220000
ENCODING 9557
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
E0
20
E0
20
20
ENDCHAR
STARTCHAR SF210000
ENCODING 9558
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
F0
50
50
50
ENDCHAR
STARTCHAR SF250000
ENCODING 9559
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F0
10
D0
50
50
ENDCHAR
STARTCHAR SF500000
ENCODING 9560
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
38
20
38
00
00
ENDCHAR
STARTCHAR SF490000
ENCODING 9561
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
50
78
00
00
00
ENDCHAR
STARTCHAR SF380000
ENCODING 9562
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
58
40
78
00
00
ENDCHAR
STARTCHAR SF280000
ENCODING 9563
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
E0
20
E0
00
00
ENDCHAR
STARTCHAR SF270000
ENCODING 9564
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
50
F0
00
00
00
ENDCHAR
STARTCHAR SF260000
ENCODING 9565
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
D0
10
F0
00
00
ENDCHAR
STARTCHAR SF360000
ENCODING 9566
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
38
20
38
20
20
ENDCHAR
STARTCHAR SF370000
ENCODING 9567
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
50
58
50
50
50
ENDCHAR
STARTCHAR SF420000
ENCODING 9568
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
58
40
58
50
50
ENDCHAR
STARTCHAR SF190000
ENCODING 9569
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
E0
20
E0
20
20
ENDCHAR
STARTCHAR SF200000
ENCODING 9570
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
50
D0
50
50
50
ENDCHAR
STARTCHAR SF230000
ENCODING 9571
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
D0
10
D0
50
50
ENDCHAR
STARTCHAR SF470000
ENCODING 9572
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F8
00
F8
20
20
ENDCHAR
STARTCHAR SF480000
ENCODING 9573
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
F8
50
50
50
ENDCHAR
STARTCHAR SF410000
ENCODING 9574
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F8
00
D8
50
50
ENDCHAR
STARTCHAR SF450000
ENCODING 9575
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
F8
00
F8
00
00
ENDCHAR
STARTCHAR SF460000
ENCODING 9576
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
50
F8
00
00
00
ENDCHAR
STARTCHAR SF400000
ENCODING 9577
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
D8
00
F8
00
00
ENDCHAR
STARTCHAR SF540000
ENCODING 9578
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
F8
20
F8
20
20
ENDCHAR
STARTCHAR SF530000
ENCODING 9579
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
50
F8
50
50
50
ENDCHAR
STARTCHAR SF440000
ENCODING 9580
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
50
D8
00
D8
50
50
ENDCHAR
STARTCHAR uni256D
ENCODING 9581
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
18
20
20
20
ENDCHAR
STARTCHAR uni256E
ENCODING 9582
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
C0
20
20
20
ENDCHAR
STARTCHAR uni256F
ENCODING 9583
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
20
C0
00
00
00
ENDCHAR
STARTCHAR uni2570
ENCODING 9584
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
20
18
00
00
00
ENDCHAR
STARTCHAR uni2571
ENCODING 9585
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
08
10
10
20
40
40
80
ENDCHAR
STARTCHAR uni2572
ENCODING 9586
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
40
40
20
10
10
08
ENDCHAR
STARTCHAR uni2573
ENCODING 9587
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
88
50
50
20
50
50
88
ENDCHAR
STARTCHAR uni2574
ENCODING 9588
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
E0
00
00
00
ENDCHAR
STARTCHAR uni2575
ENCODING 9589
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
20
20
00
00
00
ENDCHAR
STARTCHAR uni2576
ENCODING 9590
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
38
00
00
00
ENDCHAR
STARTCHAR uni2577
ENCODING 9591
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
20
20
20
20
ENDCHAR
STARTCHAR uni2578
ENCODING 9592
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
E0
E0
00
00
00
ENDCHAR
STARTCHAR uni2579
ENCODING 9593
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
30
30
30
00
00
00
ENDCHAR
STARTCHAR uni257A
ENCODING 9594
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
38
38
00
00
00
ENDCHAR
STARTCHAR uni257B
ENCODING 9595
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
30
30
30
30
ENDCHAR
STARTCHAR uni257C
ENCODING 9596
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
38
F8
00
00
00
ENDCHAR
STARTCHAR uni257D
ENCODING 9597
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
20
30
30
30
30
ENDCHAR
STARTCHAR uni257E
ENCODING 9598
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
E0
F8
00
00
00
ENDCHAR
STARTCHAR uni257F
ENCODING 9599
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
30
30
30
20
20
20
ENDCHAR
STARTCHAR upblock
ENCODING 9600
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F8
F8
F8
00
00
00
00
ENDCHAR
STARTCHAR uni2581
ENCODING 9601
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
00
00
F8
ENDCHAR
STARTCHAR uni2582
ENCODING 9602
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
00
F8
F8
ENDCHAR
STARTCHAR uni2583
ENCODING 9603
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
F8
F8
F8
ENDCHAR
STARTCHAR dnblock
ENCODING 9604
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
F8
F8
F8
F8
ENDCHAR
STARTCHAR uni2585
ENCODING 9605
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
F8
F8
F8
F8
ENDCHAR
STARTCHAR uni2586
ENCODING 9606
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F8
F8
F8
F8
F8
ENDCHAR
STARTCHAR uni2587
ENCODING 9607
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
F8
F8
F8
F8
F8
F8
ENDCHAR
STARTCHAR block
ENCODING 9608
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F8
F8
F8
F8
F8
F8
F8
ENDCHAR
STARTCHAR uni2589
ENCODING 9609
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
F0
F0
F0
F0
F0
F0
ENDCHAR
STARTCHAR uni258A
ENCODING 9610
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F0
F0
F0
F0
F0
F0
F0
ENDCHAR
STARTCHAR uni258B
ENCODING 9611
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
E0
E0
E0
E0
E0
E0
ENDCHAR
STARTCHAR lfblock
ENCODING 9612
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
E0
E0
E0
E0
E0
E0
ENDCHAR
STARTCHAR uni258D
ENCODING 9613
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
C0
C0
C0
C0
C0
C0
C0
ENDCHAR
STARTCHAR uni258E
ENCODING 9614
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
80
80
80
80
80
80
ENDCHAR
STARTCHAR uni258F
ENCODING 9615
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
80
80
80
80
80
80
ENDCHAR
STARTCHAR rtblock
ENCODING 9616
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
18
18
18
18
18
18
18
ENDCHAR
STARTCHAR ltshade
ENCODING 9617
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
10
40
10
40
10
00
ENDCHAR
STARTCHAR shade
ENCODING 9618
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
A8
50
A8
50
A8
50
A8
ENDCHAR
STARTCHAR dkshade
ENCODING 9619
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
B8
E8
B8
E8
B8
E8
F8
ENDCHAR
STARTCHAR uni2594
ENCODING 9620
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F8
00
00
00
00
00
00
ENDCHAR
STARTCHAR uni2595
ENCODING 9621
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
08
08
08
08
08
08
08
ENDCHAR
STARTCHAR uni2596
ENCODING 9622
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
E0
E0
E0
E0
ENDCHAR
STARTCHAR uni2597
ENCODING 9623
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
18
18
18
18
ENDCHAR
STARTCHAR uni2598
ENCODING 9624
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
E0
E0
00
00
00
00
ENDCHAR
STARTCHAR uni2599
ENCODING 9625
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
E0
E0
F8
F8
F8
F8
ENDCHAR
STARTCHAR uni259A
ENCODING 9626
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
E0
E0
E0
18
18
18
18
ENDCHAR
STARTCHAR uni259B
ENCODING 9627
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F8
F8
F8
E0
E0
E0
E0
ENDCHAR
STARTCHAR uni259C
ENCODING 9628
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F8
F8
F8
18
18
18
18
ENDCHAR
STARTCHAR uni259D
ENCODING 9629
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
18
18
18
00
00
00
00
ENDCHAR
STARTCHAR uni259E
ENCODING 9630
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
18
18
18
E0
E0
E0
E0
ENDCHAR
STARTCHAR uni259F
ENCODING 9631
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
18
18
18
F8
F8
F8
F8
ENDCHAR
STARTCHAR filledbox
ENCODING 9632
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F0
F0
F0
F0
00
ENDCHAR
STARTCHAR H22073
ENCODING 9633
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F0
90
90
F0
00
ENDCHAR
STARTCHAR H18543
ENCODING 9642
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
70
70
00
00
ENDCHAR
STARTCHAR H18551
ENCODING 9643
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
70
50
70
00
00
ENDCHAR
STARTCHAR filledrect
ENCODING 9644
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F8
F8
F8
00
00
ENDCHAR
STARTCHAR uni25AD
ENCODING 9645
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
F8
88
F8
00
00
ENDCHAR
STARTCHAR uni25AE
ENCODING 9646
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
70
70
70
70
70
00
ENDCHAR
STARTCHAR triagup
ENCODING 9650
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
70
70
F8
F8
00
ENDCHAR
STARTCHAR uni25B3
ENCODING 9651
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
20
50
50
88
F8
00
ENDCHAR
STARTCHAR uni25B6
ENCODING 9654
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
C0
E0
F0
E0
C0
80
ENDCHAR
STARTCHAR uni25B7
ENCODING 9655
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
80
C0
A0
90
A0
C0
80
ENDCHAR
STARTCHAR uni25B8
ENCODING 9656
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
40
60
70
60
40
00
ENDCHAR
STARTCHAR uni25B9
ENCODING 9657
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
40
60
50
60
40
00
ENDCHAR
STARTCHAR triagrt
ENCODING 9658
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
80
E0
F8
E0
80
00
ENDCHAR
STARTCHAR uni25BB
ENCODING 9659
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
80
E0
98
E0
80
00
ENDCHAR
STARTCHAR triagdn
ENCODING 9660
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F8
F8
70
70
20
20
00
ENDCHAR
STARTCHAR uni25BD
ENCODING 9661
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F8
88
50
50
20
20
00
ENDCHAR
STARTCHAR uni25C0
ENCODING 9664
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
30
70
F0
70
30
10
ENDCHAR
STARTCHAR uni25C1
ENCODING 9665
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
30
50
90
50
30
10
ENDCHAR
STARTCHAR uni25C2
ENCODING 9666
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
10
30
70
30
10
00
ENDCHAR
STARTCHAR uni25C3
ENCODING 9667
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
10
30
50
30
10
00
ENDCHAR
STARTCHAR triaglf
ENCODING 9668
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
08
38
F8
38
08
00
ENDCHAR
STARTCHAR uni25C5
ENCODING 9669
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
08
38
C8
38
08
00
ENDCHAR
STARTCHAR uni25C6
ENCODING 9670
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
20
70
F8
70
20
00
ENDCHAR
STARTCHAR lozenge
ENCODING 9674
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
20
50
88
50
20
00
ENDCHAR
STARTCHAR circle
ENCODING 9675
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
70
88
88
88
70
00
ENDCHAR
STARTCHAR H18533
ENCODING 9679
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
70
F8
F8
F8
70
00
ENDCHAR
STARTCHAR invbullet
ENCODING 9688
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F8
F8
D8
88
D8
F8
F8
ENDCHAR
STARTCHAR invcircle
ENCODING 9689
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
F8
F8
D8
A8
D8
F8
F8
ENDCHAR
STARTCHAR openbullet
ENCODING 9702
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
60
90
90
60
00
ENDCHAR
STARTCHAR uni2639
ENCODING 9785
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
50
00
20
50
00
00
ENDCHAR
STARTCHAR smileface
ENCODING 9786
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
50
00
50
20
00
00
ENDCHAR
STARTCHAR invsmileface
ENCODING 9787
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
A8
F8
A8
D8
70
00
ENDCHAR
STARTCHAR sun
ENCODING 9788
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
A8
70
D8
70
A8
20
ENDCHAR
STARTCHAR female
ENCODING 9792
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
20
50
20
70
20
00
ENDCHAR
STARTCHAR uni2641
ENCODING 9793
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
20
70
20
50
20
00
ENDCHAR
STARTCHAR male
ENCODING 9794
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
38
18
68
A0
40
00
00
ENDCHAR
STARTCHAR spade
ENCODING 9824
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
70
F8
F8
20
70
00
ENDCHAR
STARTCHAR club
ENCODING 9827
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
70
A8
F8
A8
20
70
ENDCHAR
STARTCHAR heart
ENCODING 9829
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
F8
F8
70
70
20
00
ENDCHAR
STARTCHAR diamond
ENCODING 9830
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
70
F8
F8
70
20
00
ENDCHAR
STARTCHAR uni2669
ENCODING 9833
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
10
10
30
70
20
00
ENDCHAR
STARTCHAR musicalnote
ENCODING 9834
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
30
28
60
E0
40
00
ENDCHAR
STARTCHAR musicalnotedbl
ENCODING 9835
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
60
58
48
C8
D8
18
00
ENDCHAR
STARTCHAR uni266C
ENCODING 9836
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
70
68
58
C8
D8
18
00
ENDCHAR
STARTCHAR uni266D
ENCODING 9837
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
40
70
50
50
60
00
ENDCHAR
STARTCHAR uni266E
ENCODING 9838
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
70
50
50
70
10
00
ENDCHAR
STARTCHAR uni266F
ENCODING 9839
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
58
70
D8
70
D0
40
ENDCHAR
STARTCHAR uni2800
ENCODING 10240
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
00
00
00
ENDCHAR
STARTCHAR uni2801
ENCODING 10241
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
00
00
00
00
00
ENDCHAR
STARTCHAR uni2802
ENCODING 10242
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
40
00
00
00
00
ENDCHAR
STARTCHAR uni2803
ENCODING 10243
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
40
00
00
00
00
ENDCHAR
STARTCHAR uni2804
ENCODING 10244
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
40
00
00
ENDCHAR
STARTCHAR uni2805
ENCODING 10245
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
00
00
40
00
00
ENDCHAR
STARTCHAR uni2806
ENCODING 10246
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
40
00
40
00
00
ENDCHAR
STARTCHAR uni2807
ENCODING 10247
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
40
00
40
00
00
ENDCHAR
STARTCHAR uni2808
ENCODING 10248
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
00
00
00
00
00
ENDCHAR
STARTCHAR uni2809
ENCODING 10249
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
00
00
00
00
00
ENDCHAR
STARTCHAR uni280A
ENCODING 10250
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
40
00
00
00
00
ENDCHAR
STARTCHAR uni280B
ENCODING 10251
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
40
00
00
00
00
ENDCHAR
STARTCHAR uni280C
ENCODING 10252
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
00
00
40
00
00
ENDCHAR
STARTCHAR uni280D
ENCODING 10253
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
00
00
40
00
00
ENDCHAR
STARTCHAR uni280E
ENCODING 10254
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
40
00
40
00
00
ENDCHAR
STARTCHAR uni280F
ENCODING 10255
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
40
00
40
00
00
ENDCHAR
STARTCHAR uni2810
ENCODING 10256
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
10
00
00
00
00
ENDCHAR
STARTCHAR uni2811
ENCODING 10257
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
10
00
00
00
00
ENDCHAR
STARTCHAR uni2812
ENCODING 10258
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
00
00
00
00
ENDCHAR
STARTCHAR uni2813
ENCODING 10259
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
50
00
00
00
00
ENDCHAR
STARTCHAR uni2814
ENCODING 10260
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
10
00
40
00
00
ENDCHAR
STARTCHAR uni2815
ENCODING 10261
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
10
00
40
00
00
ENDCHAR
STARTCHAR uni2816
ENCODING 10262
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
00
40
00
00
ENDCHAR
STARTCHAR uni2817
ENCODING 10263
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
50
00
40
00
00
ENDCHAR
STARTCHAR uni2818
ENCODING 10264
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
10
00
00
00
00
ENDCHAR
STARTCHAR uni2819
ENCODING 10265
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
10
00
00
00
00
ENDCHAR
STARTCHAR uni281A
ENCODING 10266
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
50
00
00
00
00
ENDCHAR
STARTCHAR uni281B
ENCODING 10267
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
50
00
00
00
00
ENDCHAR
STARTCHAR uni281C
ENCODING 10268
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
10
00
40
00
00
ENDCHAR
STARTCHAR uni281D
ENCODING 10269
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
10
00
40
00
00
ENDCHAR
STARTCHAR uni281E
ENCODING 10270
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
50
00
40
00
00
ENDCHAR
STARTCHAR uni281F
ENCODING 10271
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
50
00
40
00
00
ENDCHAR
STARTCHAR uni2820
ENCODING 10272
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
10
00
00
ENDCHAR
STARTCHAR uni2821
ENCODING 10273
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
00
00
10
00
00
ENDCHAR
STARTCHAR uni2822
ENCODING 10274
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
40
00
10
00
00
ENDCHAR
STARTCHAR uni2823
ENCODING 10275
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
40
00
10
00
00
ENDCHAR
STARTCHAR uni2824
ENCODING 10276
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
50
00
00
ENDCHAR
STARTCHAR uni2825
ENCODING 10277
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
00
00
50
00
00
ENDCHAR
STARTCHAR uni2826
ENCODING 10278
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
40
00
50
00
00
ENDCHAR
STARTCHAR uni2827
ENCODING 10279
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
40
00
50
00
00
ENDCHAR
STARTCHAR uni2828
ENCODING 10280
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
00
00
10
00
00
ENDCHAR
STARTCHAR uni2829
ENCODING 10281
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
00
00
10
00
00
ENDCHAR
STARTCHAR uni282A
ENCODING 10282
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
40
00
10
00
00
ENDCHAR
STARTCHAR uni282B
ENCODING 10283
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
40
00
10
00
00
ENDCHAR
STARTCHAR uni282C
ENCODING 10284
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
00
00
50
00
00
ENDCHAR
STARTCHAR uni282D
ENCODING 10285
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
00
00
50
00
00
ENDCHAR
STARTCHAR uni282E
ENCODING 10286
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
40
00
50
00
00
ENDCHAR
STARTCHAR uni282F
ENCODING 10287
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
40
00
50
00
00
ENDCHAR
STARTCHAR uni2830
ENCODING 10288
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
10
00
10
00
00
ENDCHAR
STARTCHAR uni2831
ENCODING 10289
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
10
00
10
00
00
ENDCHAR
STARTCHAR uni2832
ENCODING 10290
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
00
10
00
00
ENDCHAR
STARTCHAR uni2833
ENCODING 10291
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
50
00
10
00
00
ENDCHAR
STARTCHAR uni2834
ENCODING 10292
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
10
00
50
00
00
ENDCHAR
STARTCHAR uni2835
ENCODING 10293
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
10
00
50
00
00
ENDCHAR
STARTCHAR uni2836
ENCODING 10294
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
00
50
00
00
ENDCHAR
STARTCHAR uni2837
ENCODING 10295
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
50
00
50
00
00
ENDCHAR
STARTCHAR uni2838
ENCODING 10296
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
10
00
10
00
00
ENDCHAR
STARTCHAR uni2839
ENCODING 10297
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
10
00
10
00
00
ENDCHAR
STARTCHAR uni283A
ENCODING 10298
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
50
00
10
00
00
ENDCHAR
STARTCHAR uni283B
ENCODING 10299
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
50
00
10
00
00
ENDCHAR
STARTCHAR uni283C
ENCODING 10300
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
10
00
50
00
00
ENDCHAR
STARTCHAR uni283D
ENCODING 10301
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
10
00
50
00
00
ENDCHAR
STARTCHAR uni283E
ENCODING 10302
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
50
00
50
00
00
ENDCHAR
STARTCHAR uni283F
ENCODING 10303
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
50
00
50
00
00
ENDCHAR
STARTCHAR uni2840
ENCODING 10304
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
00
00
40
ENDCHAR
STARTCHAR uni2841
ENCODING 10305
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
00
00
00
00
40
ENDCHAR
STARTCHAR uni2842
ENCODING 10306
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
40
00
00
00
40
ENDCHAR
STARTCHAR uni2843
ENCODING 10307
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
40
00
00
00
40
ENDCHAR
STARTCHAR uni2844
ENCODING 10308
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
40
00
40
ENDCHAR
STARTCHAR uni2845
ENCODING 10309
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
00
00
40
00
40
ENDCHAR
STARTCHAR uni2846
ENCODING 10310
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
40
00
40
00
40
ENDCHAR
STARTCHAR uni2847
ENCODING 10311
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
40
00
40
00
40
ENDCHAR
STARTCHAR uni2848
ENCODING 10312
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
00
00
00
00
40
ENDCHAR
STARTCHAR uni2849
ENCODING 10313
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
00
00
00
00
40
ENDCHAR
STARTCHAR uni284A
ENCODING 10314
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
40
00
00
00
40
ENDCHAR
STARTCHAR uni284B
ENCODING 10315
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
40
00
00
00
40
ENDCHAR
STARTCHAR uni284C
ENCODING 10316
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
00
00
40
00
40
ENDCHAR
STARTCHAR uni284D
ENCODING 10317
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
00
00
40
00
40
ENDCHAR
STARTCHAR uni284E
ENCODING 10318
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
40
00
40
00
40
ENDCHAR
STARTCHAR uni284F
ENCODING 10319
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
40
00
40
00
40
ENDCHAR
STARTCHAR uni2850
ENCODING 10320
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
10
00
00
00
40
ENDCHAR
STARTCHAR uni2851
ENCODING 10321
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
10
00
00
00
40
ENDCHAR
STARTCHAR uni2852
ENCODING 10322
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
00
00
00
40
ENDCHAR
STARTCHAR uni2853
ENCODING 10323
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
50
00
00
00
40
ENDCHAR
STARTCHAR uni2854
ENCODING 10324
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
10
00
40
00
40
ENDCHAR
STARTCHAR uni2855
ENCODING 10325
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
10
00
40
00
40
ENDCHAR
STARTCHAR uni2856
ENCODING 10326
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
00
40
00
40
ENDCHAR
STARTCHAR uni2857
ENCODING 10327
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
50
00
40
00
40
ENDCHAR
STARTCHAR uni2858
ENCODING 10328
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
10
00
00
00
40
ENDCHAR
STARTCHAR uni2859
ENCODING 10329
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
10
00
00
00
40
ENDCHAR
STARTCHAR uni285A
ENCODING 10330
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
50
00
00
00
40
ENDCHAR
STARTCHAR uni285B
ENCODING 10331
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
50
00
00
00
40
ENDCHAR
STARTCHAR uni285C
ENCODING 10332
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
10
00
40
00
40
ENDCHAR
STARTCHAR uni285D
ENCODING 10333
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
10
00
40
00
40
ENDCHAR
STARTCHAR uni285E
ENCODING 10334
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
50
00
40
00
40
ENDCHAR
STARTCHAR uni285F
ENCODING 10335
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
50
00
40
00
40
ENDCHAR
STARTCHAR uni2860
ENCODING 10336
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
10
00
40
ENDCHAR
STARTCHAR uni2861
ENCODING 10337
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
00
00
10
00
40
ENDCHAR
STARTCHAR uni2862
ENCODING 10338
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
40
00
10
00
40
ENDCHAR
STARTCHAR uni2863
ENCODING 10339
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
40
00
10
00
40
ENDCHAR
STARTCHAR uni2864
ENCODING 10340
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
50
00
40
ENDCHAR
STARTCHAR uni2865
ENCODING 10341
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
00
00
50
00
40
ENDCHAR
STARTCHAR uni2866
ENCODING 10342
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
40
00
50
00
40
ENDCHAR
STARTCHAR uni2867
ENCODING 10343
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
40
00
50
00
40
ENDCHAR
STARTCHAR uni2868
ENCODING 10344
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
00
00
10
00
40
ENDCHAR
STARTCHAR uni2869
ENCODING 10345
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
00
00
10
00
40
ENDCHAR
STARTCHAR uni286A
ENCODING 10346
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
40
00
10
00
40
ENDCHAR
STARTCHAR uni286B
ENCODING 10347
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
40
00
10
00
40
ENDCHAR
STARTCHAR uni286C
ENCODING 10348
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
00
00
50
00
40
ENDCHAR
STARTCHAR uni286D
ENCODING 10349
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
00
00
50
00
40
ENDCHAR
STARTCHAR uni286E
ENCODING 10350
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
40
00
50
00
40
ENDCHAR
STARTCHAR uni286F
ENCODING 10351
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
40
00
50
00
40
ENDCHAR
STARTCHAR uni2870
ENCODING 10352
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
10
00
10
00
40
ENDCHAR
STARTCHAR uni2871
ENCODING 10353
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
10
00
10
00
40
ENDCHAR
STARTCHAR uni2872
ENCODING 10354
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
00
10
00
40
ENDCHAR
STARTCHAR uni2873
ENCODING 10355
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
50
00
10
00
40
ENDCHAR
STARTCHAR uni2874
ENCODING 10356
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
10
00
50
00
40
ENDCHAR
STARTCHAR uni2875
ENCODING 10357
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
10
00
50
00
40
ENDCHAR
STARTCHAR uni2876
ENCODING 10358
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
00
50
00
40
ENDCHAR
STARTCHAR uni2877
ENCODING 10359
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
50
00
50
00
40
ENDCHAR
STARTCHAR uni2878
ENCODING 10360
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
10
00
10
00
40
ENDCHAR
STARTCHAR uni2879
ENCODING 10361
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
10
00
10
00
40
ENDCHAR
STARTCHAR uni287A
ENCODING 10362
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
50
00
10
00
40
ENDCHAR
STARTCHAR uni287B
ENCODING 10363
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
50
00
10
00
40
ENDCHAR
STARTCHAR uni287C
ENCODING 10364
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
10
00
50
00
40
ENDCHAR
STARTCHAR uni287D
ENCODING 10365
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
10
00
50
00
40
ENDCHAR
STARTCHAR uni287E
ENCODING 10366
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
50
00
50
00
40
ENDCHAR
STARTCHAR uni287F
ENCODING 10367
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
50
00
50
00
40
ENDCHAR
STARTCHAR uni2880
ENCODING 10368
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
00
00
10
ENDCHAR
STARTCHAR uni2881
ENCODING 10369
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
00
00
00
00
10
ENDCHAR
STARTCHAR uni2882
ENCODING 10370
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
40
00
00
00
10
ENDCHAR
STARTCHAR uni2883
ENCODING 10371
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
40
00
00
00
10
ENDCHAR
STARTCHAR uni2884
ENCODING 10372
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
40
00
10
ENDCHAR
STARTCHAR uni2885
ENCODING 10373
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
00
00
40
00
10
ENDCHAR
STARTCHAR uni2886
ENCODING 10374
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
40
00
40
00
10
ENDCHAR
STARTCHAR uni2887
ENCODING 10375
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
40
00
40
00
10
ENDCHAR
STARTCHAR uni2888
ENCODING 10376
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
00
00
00
00
10
ENDCHAR
STARTCHAR uni2889
ENCODING 10377
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
00
00
00
00
10
ENDCHAR
STARTCHAR uni288A
ENCODING 10378
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
40
00
00
00
10
ENDCHAR
STARTCHAR uni288B
ENCODING 10379
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
40
00
00
00
10
ENDCHAR
STARTCHAR uni288C
ENCODING 10380
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
00
00
40
00
10
ENDCHAR
STARTCHAR uni288D
ENCODING 10381
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
00
00
40
00
10
ENDCHAR
STARTCHAR uni288E
ENCODING 10382
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
40
00
40
00
10
ENDCHAR
STARTCHAR uni288F
ENCODING 10383
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
40
00
40
00
10
ENDCHAR
STARTCHAR uni2890
ENCODING 10384
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
10
00
00
00
10
ENDCHAR
STARTCHAR uni2891
ENCODING 10385
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
10
00
00
00
10
ENDCHAR
STARTCHAR uni2892
ENCODING 10386
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
00
00
00
10
ENDCHAR
STARTCHAR uni2893
ENCODING 10387
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
50
00
00
00
10
ENDCHAR
STARTCHAR uni2894
ENCODING 10388
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
10
00
40
00
10
ENDCHAR
STARTCHAR uni2895
ENCODING 10389
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
10
00
40
00
10
ENDCHAR
STARTCHAR uni2896
ENCODING 10390
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
00
40
00
10
ENDCHAR
STARTCHAR uni2897
ENCODING 10391
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
50
00
40
00
10
ENDCHAR
STARTCHAR uni2898
ENCODING 10392
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
10
00
00
00
10
ENDCHAR
STARTCHAR uni2899
ENCODING 10393
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
10
00
00
00
10
ENDCHAR
STARTCHAR uni289A
ENCODING 10394
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
50
00
00
00
10
ENDCHAR
STARTCHAR uni289B
ENCODING 10395
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
50
00
00
00
10
ENDCHAR
STARTCHAR uni289C
ENCODING 10396
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
10
00
40
00
10
ENDCHAR
STARTCHAR uni289D
ENCODING 10397
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
10
00
40
00
10
ENDCHAR
STARTCHAR uni289E
ENCODING 10398
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
50
00
40
00
10
ENDCHAR
STARTCHAR uni289F
ENCODING 10399
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
50
00
40
00
10
ENDCHAR
STARTCHAR uni28A0
ENCODING 10400
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
10
00
10
ENDCHAR
STARTCHAR uni28A1
ENCODING 10401
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
00
00
10
00
10
ENDCHAR
STARTCHAR uni28A2
ENCODING 10402
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
40
00
10
00
10
ENDCHAR
STARTCHAR uni28A3
ENCODING 10403
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
40
00
10
00
10
ENDCHAR
STARTCHAR uni28A4
ENCODING 10404
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
50
00
10
ENDCHAR
STARTCHAR uni28A5
ENCODING 10405
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
00
00
50
00
10
ENDCHAR
STARTCHAR uni28A6
ENCODING 10406
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
40
00
50
00
10
ENDCHAR
STARTCHAR uni28A7
ENCODING 10407
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
40
00
50
00
10
ENDCHAR
STARTCHAR uni28A8
ENCODING 10408
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
00
00
10
00
10
ENDCHAR
STARTCHAR uni28A9
ENCODING 10409
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
00
00
10
00
10
ENDCHAR
STARTCHAR uni28AA
ENCODING 10410
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
40
00
10
00
10
ENDCHAR
STARTCHAR uni28AB
ENCODING 10411
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
40
00
10
00
10
ENDCHAR
STARTCHAR uni28AC
ENCODING 10412
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
00
00
50
00
10
ENDCHAR
STARTCHAR uni28AD
ENCODING 10413
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
00
00
50
00
10
ENDCHAR
STARTCHAR uni28AE
ENCODING 10414
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
40
00
50
00
10
ENDCHAR
STARTCHAR uni28AF
ENCODING 10415
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
40
00
50
00
10
ENDCHAR
STARTCHAR uni28B0
ENCODING 10416
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
10
00
10
00
10
ENDCHAR
STARTCHAR uni28B1
ENCODING 10417
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
10
00
10
00
10
ENDCHAR
STARTCHAR uni28B2
ENCODING 10418
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
00
10
00
10
ENDCHAR
STARTCHAR uni28B3
ENCODING 10419
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
50
00
10
00
10
ENDCHAR
STARTCHAR uni28B4
ENCODING 10420
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
10
00
50
00
10
ENDCHAR
STARTCHAR uni28B5
ENCODING 10421
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
10
00
50
00
10
ENDCHAR
STARTCHAR uni28B6
ENCODING 10422
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
00
50
00
10
ENDCHAR
STARTCHAR uni28B7
ENCODING 10423
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
50
00
50
00
10
ENDCHAR
STARTCHAR uni28B8
ENCODING 10424
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
10
00
10
00
10
ENDCHAR
STARTCHAR uni28B9
ENCODING 10425
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
10
00
10
00
10
ENDCHAR
STARTCHAR uni28BA
ENCODING 10426
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
50
00
10
00
10
ENDCHAR
STARTCHAR uni28BB
ENCODING 10427
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
50
00
10
00
10
ENDCHAR
STARTCHAR uni28BC
ENCODING 10428
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
10
00
50
00
10
ENDCHAR
STARTCHAR uni28BD
ENCODING 10429
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
10
00
50
00
10
ENDCHAR
STARTCHAR uni28BE
ENCODING 10430
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
50
00
50
00
10
ENDCHAR
STARTCHAR uni28BF
ENCODING 10431
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
50
00
50
00
10
ENDCHAR
STARTCHAR uni28C0
ENCODING 10432
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
00
00
50
ENDCHAR
STARTCHAR uni28C1
ENCODING 10433
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
00
00
00
00
50
ENDCHAR
STARTCHAR uni28C2
ENCODING 10434
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
40
00
00
00
50
ENDCHAR
STARTCHAR uni28C3
ENCODING 10435
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
40
00
00
00
50
ENDCHAR
STARTCHAR uni28C4
ENCODING 10436
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
40
00
50
ENDCHAR
STARTCHAR uni28C5
ENCODING 10437
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
00
00
40
00
50
ENDCHAR
STARTCHAR uni28C6
ENCODING 10438
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
40
00
40
00
50
ENDCHAR
STARTCHAR uni28C7
ENCODING 10439
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
40
00
40
00
50
ENDCHAR
STARTCHAR uni28C8
ENCODING 10440
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
00
00
00
00
50
ENDCHAR
STARTCHAR uni28C9
ENCODING 10441
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
00
00
00
00
50
ENDCHAR
STARTCHAR uni28CA
ENCODING 10442
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
40
00
00
00
50
ENDCHAR
STARTCHAR uni28CB
ENCODING 10443
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
40
00
00
00
50
ENDCHAR
STARTCHAR uni28CC
ENCODING 10444
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
00
00
40
00
50
ENDCHAR
STARTCHAR uni28CD
ENCODING 10445
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
00
00
40
00
50
ENDCHAR
STARTCHAR uni28CE
ENCODING 10446
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
40
00
40
00
50
ENDCHAR
STARTCHAR uni28CF
ENCODING 10447
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
40
00
40
00
50
ENDCHAR
STARTCHAR uni28D0
ENCODING 10448
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
10
00
00
00
50
ENDCHAR
STARTCHAR uni28D1
ENCODING 10449
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
10
00
00
00
50
ENDCHAR
STARTCHAR uni28D2
ENCODING 10450
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
00
00
00
50
ENDCHAR
STARTCHAR uni28D3
ENCODING 10451
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
50
00
00
00
50
ENDCHAR
STARTCHAR uni28D4
ENCODING 10452
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
10
00
40
00
50
ENDCHAR
STARTCHAR uni28D5
ENCODING 10453
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
10
00
40
00
50
ENDCHAR
STARTCHAR uni28D6
ENCODING 10454
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
00
40
00
50
ENDCHAR
STARTCHAR uni28D7
ENCODING 10455
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
50
00
40
00
50
ENDCHAR
STARTCHAR uni28D8
ENCODING 10456
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
10
00
00
00
50
ENDCHAR
STARTCHAR uni28D9
ENCODING 10457
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
10
00
00
00
50
ENDCHAR
STARTCHAR uni28DA
ENCODING 10458
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
50
00
00
00
50
ENDCHAR
STARTCHAR uni28DB
ENCODING 10459
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
50
00
00
00
50
ENDCHAR
STARTCHAR uni28DC
ENCODING 10460
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
10
00
40
00
50
ENDCHAR
STARTCHAR uni28DD
ENCODING 10461
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
10
00
40
00
50
ENDCHAR
STARTCHAR uni28DE
ENCODING 10462
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
50
00
40
00
50
ENDCHAR
STARTCHAR uni28DF
ENCODING 10463
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
50
00
40
00
50
ENDCHAR
STARTCHAR uni28E0
ENCODING 10464
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
10
00
50
ENDCHAR
STARTCHAR uni28E1
ENCODING 10465
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
00
00
10
00
50
ENDCHAR
STARTCHAR uni28E2
ENCODING 10466
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
40
00
10
00
50
ENDCHAR
STARTCHAR uni28E3
ENCODING 10467
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
40
00
10
00
50
ENDCHAR
STARTCHAR uni28E4
ENCODING 10468
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
00
00
50
00
50
ENDCHAR
STARTCHAR uni28E5
ENCODING 10469
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
00
00
50
00
50
ENDCHAR
STARTCHAR uni28E6
ENCODING 10470
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
40
00
50
00
50
ENDCHAR
STARTCHAR uni28E7
ENCODING 10471
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
40
00
50
00
50
ENDCHAR
STARTCHAR uni28E8
ENCODING 10472
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
00
00
10
00
50
ENDCHAR
STARTCHAR uni28E9
ENCODING 10473
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
00
00
10
00
50
ENDCHAR
STARTCHAR uni28EA
ENCODING 10474
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
40
00
10
00
50
ENDCHAR
STARTCHAR uni28EB
ENCODING 10475
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
40
00
10
00
50
ENDCHAR
STARTCHAR uni28EC
ENCODING 10476
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
00
00
50
00
50
ENDCHAR
STARTCHAR uni28ED
ENCODING 10477
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
00
00
50
00
50
ENDCHAR
STARTCHAR uni28EE
ENCODING 10478
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
40
00
50
00
50
ENDCHAR
STARTCHAR uni28EF
ENCODING 10479
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
40
00
50
00
50
ENDCHAR
STARTCHAR uni28F0
ENCODING 10480
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
10
00
10
00
50
ENDCHAR
STARTCHAR uni28F1
ENCODING 10481
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
10
00
10
00
50
ENDCHAR
STARTCHAR uni28F2
ENCODING 10482
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
00
10
00
50
ENDCHAR
STARTCHAR uni28F3
ENCODING 10483
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
50
00
10
00
50
ENDCHAR
STARTCHAR uni28F4
ENCODING 10484
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
10
00
50
00
50
ENDCHAR
STARTCHAR uni28F5
ENCODING 10485
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
10
00
50
00
50
ENDCHAR
STARTCHAR uni28F6
ENCODING 10486
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
00
00
50
00
50
00
50
ENDCHAR
STARTCHAR uni28F7
ENCODING 10487
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
40
00
50
00
50
00
50
ENDCHAR
STARTCHAR uni28F8
ENCODING 10488
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
10
00
10
00
50
ENDCHAR
STARTCHAR uni28F9
ENCODING 10489
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
10
00
10
00
50
ENDCHAR
STARTCHAR uni28FA
ENCODING 10490
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
50
00
10
00
50
ENDCHAR
STARTCHAR uni28FB
ENCODING 10491
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
50
00
10
00
50
ENDCHAR
STARTCHAR uni28FC
ENCODING 10492
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
10
00
50
00
50
ENDCHAR
STARTCHAR uni28FD
ENCODING 10493
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
10
00
50
00
50
ENDCHAR
STARTCHAR uni28FE
ENCODING 10494
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
10
00
50
00
50
00
50
ENDCHAR
STARTCHAR uni28FF
ENCODING 10495
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
00
50
00
50
00
50
ENDCHAR
STARTCHAR fi
ENCODING 64257
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
20
50
40
F0
50
50
00
ENDCHAR
STARTCHAR fl
ENCODING 64258
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
30
50
50
F0
50
50
00
ENDCHAR
STARTCHAR uniFFFD
ENCODING 65533
SWIDTH 685 0
DWIDTH 5 0
BBX 5 7 0 -1
BITMAP
50
A8
E8
D8
F8
D8
70
ENDCHAR
ENDFONT
