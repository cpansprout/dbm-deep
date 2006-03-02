##
# DBM::Deep Test
##
use strict;
use Test::More tests => 7;
use Test::Exception;
use File::Temp qw( tempfile tempdir );

use_ok( 'DBM::Deep' );

my $dir = tempdir();
my ($fh, $filename) = tempfile( 'tmpXXXX', UNLINK => 1, DIR => $dir );

{
    my %hash;
    tie %hash, 'DBM::Deep', $filename;

    $hash{key1} = 'value';
    is( $hash{key1}, 'value', 'Set and retrieved key1' );
}

{
    my %hash;
    tie %hash, 'DBM::Deep', $filename;

    is( $hash{key1}, 'value', 'Set and retrieved key1' );

    is( keys %hash, 1, "There's one key so far" );
    ok( exists $hash{key1}, "... and it's key1" );
}

{
    throws_ok {
        tie my @array, 'DBM::Deep', {
            file => $filename,
            type => DBM::Deep->TYPE_ARRAY,
        };
    } qr/DBM::Deep: File type mismatch/, "\$SIG_TYPE doesn't match file's type";
}

{
    my ($fh, $filename) = tempfile( 'tmpXXXX', UNLINK => 1, DIR => $dir );
    DBM::Deep->new( file => $filename, type => DBM::Deep->TYPE_ARRAY );

    throws_ok {
        tie my %hash, 'DBM::Deep', {
            file => $filename,
            type => DBM::Deep->TYPE_HASH,
        };
    } qr/DBM::Deep: File type mismatch/, "\$SIG_TYPE doesn't match file's type";
}
