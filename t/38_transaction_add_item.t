use strict;
use Test::More tests => 9;
use Test::Deep;
use t::common qw( new_fh );

use_ok( 'DBM::Deep' );

my ($fh, $filename) = new_fh();
my $db = DBM::Deep->new(
    file => $filename,
    locking => 1,
    autoflush => 1,
);

{
    my $obj = bless {
        foo => 5,
    }, 'Foo';

    cmp_ok( $obj->{foo}, '==', 5 );
    ok( !exists $obj->{bar} );

    $db->begin_work;

    $db->{foo} = $obj;
    $db->{foo}{bar} = 1;

    cmp_ok( $db->{foo}{bar}, '==', 1, "The value is visible within the transaction" );
    cmp_ok( $obj->{bar}, '==', 1, "The value is visible within the object" );

    $db->rollback;

TODO: {
    local $TODO = "Adding items in transactions will be fixed soon";
    local $^W;
    cmp_ok( $obj->{foo}, '==', 5 );
}
    ok( !exists $obj->{bar}, "bar doesn't exist" );
TODO: {
    local $TODO = "Adding items in transactions will be fixed soon";
    ok( !tied(%$obj), "And it's not tied" );
}

    ok( !exists $db->{foo}, "The transaction inside the DB works" );
}

__END__
{
    my $obj = bless {
        foo => 5,
    }, 'Foo';

    cmp_ok( $obj->{foo}, '==', 5 );
    ok( !exists $obj->{bar} );

    $db->begin_work;

    $db->{foo} = $obj;
    $db->{foo}{bar} = 1;

    cmp_ok( $db->{foo}{bar}, '==', 1, "The value is visible within the transaction" );
    cmp_ok( $obj->{bar}, '==', 1, "The value is visible within the object" );

    $db->commit;

    cmp_ok( $obj->{foo}, '==', 5 );
    ok( !exists $obj->{bar} );
}