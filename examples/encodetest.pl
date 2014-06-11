#!/usr/bin/perl

use strict;

#my @original; # = ( 0x28,0xA0,0x89,0xAD,0x03,0x00,0x00,0xAA,0x04,0x01,0x00,0x44,0x07,0xE8,0x03,0x00,0x00,0x06,0x03,0x04,0x01);

my @encoded = ( 0x00,0x26,0x1d,0x00,0x00,0x20,0x17,0x00,0x00,0x00,0x00,0x00,0x00,0x7e,0x5c,0x00,0x0a,0x6e,0x43,0x1f,0x27,0x40,0x02,0x14,0x00,0x40,0x04,0x48,0x10,0x20,0x4b,0x00,0x03,0x00,0x00,0x00,0x00,0x60,0x54,0x03,0x00,0x00,0x74,0x02,0x00,0x00,0x00,0x00,0x00,0x60,0x4f,0x0b,0x20,0x61,0x3d,0x78,0x73,0x04,0x28,0x40,0x02,0x00,0x48,0x00,0x09,0x02,0x34,0x09,0x30,0x00,0x00,0x00,0x00,0x00,0x4c,0x3a,0x00,0x00,0x40,0x2e,0x00,0x00,0x00,0x00,0x00,0x00,0x7c,0x39,0x01,0x14,0x5c,0x07,0x3f,0x4e,0x00,0x05,0x28,0x00,0x00,0x09,0x10,0x21,0x40,0x16,0x01,0x06,0x00,0x00,0x00,0x00,0x40,0x29,0x07,0x00,0x00,0x68,0x05,0x00,0x00, );

#for (my $i=0;$i<256;$i++) {
#	push(@original,$i);
#}

#my @encoded = encode(@original);

#print "encode end\n";
my $encodedsize = @encoded;

print "encoded, size: ".$encodedsize."\n";
for (my $i=0;$i<$encodedsize;$i++) {
	printf ("%02x,",$encoded[$i]);
}
print "\n";

my @decoded = decode(@encoded);

#my $size = @original;
my $decodedsize = @decoded;

#for (my $i=$size;$i>0;$i--) {
#	printf ("%X",$original[$i-1]);
#	print ",";
#}
#print "\n";
print "decoded, size: ".$decodedsize."\n";
for (my $i=0;$i<$decodedsize;$i++) {
	printf ("%02x,",$decoded[$i]);
}
print "\n";
#
#for (my $i=$size;$i>0;$i--) {
#	printf ("%b",$original[$i-1]);
#	print ",";
#}
#print "\n";
#for (my $i=$encodedsize;$i>0;$i--) {
#	printf ("%b",$encoded[$i-1]);
#	print ",";
#}
#print "\n";
#for (my $i=$decodedsize;$i>0;$i--) {
#	printf ("%b",$decoded[$i-1]);
#	print ",";
#}
#print "\n";

#for (my $i=0;$i<$size;$i++) {
#	if ($original[$i] ne $decoded[$i]) {
#		printf ("%d %X %X\n",$i,$original[$i],$decoded[$i]);
#	}
#}
#
#for (my $i=0;$i<$encodedsize;$i++) {
#	if ($encoded[$i] >> 7 > 0) {
#		printf "%d, %b\n",$i,$encoded[$i];
#	}
#}

sub encode {
	my @data = @_;
	my @outdata;
	my $numBytes    = @data;
	my $messageSize = ( $numBytes << 3 ) / 7;
	for ( my $i = 0 ; $i < $messageSize ; $i++ ) {
		my $j     = $i * 7;
		my $pos   = $j >> 3;
		my $shift = $j & 7;
		my $out   = $data[$pos] >> $shift & 0x7F;
		
		if ($out >> 7 > 0) {
			printf "%b, %b, %d\n",$data[$pos],$out,$shift;
		}
		
		if ( $shift > 1 && $pos < $numBytes-1 ) {
			$out |= ( $data[ $pos + 1 ] << ( 8 - $shift ) ) & 0x7F;
		}
		push( @outdata, $out );
	}
	return @outdata;
}

sub decode {
	my @data = @_;
	my @outdata;
	my $numBytes = @data;
	my $outBytes = ( $numBytes * 7 ) >> 3;
	for ( my $i = 0 ; $i < $outBytes ; $i++ ) {
		my $j     = $i << 3;
		my $pos   = $j / 7;
		my $shift = $j % 7;
		push( @outdata,
			( $data[$pos] >> $shift ) |
			  ( ( $data[ $pos + 1 ] << ( 7 - $shift ) ) & 0xFF ) );
	}
	return @outdata;
}