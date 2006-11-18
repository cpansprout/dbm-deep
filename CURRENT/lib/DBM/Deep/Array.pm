package DBM::Deep::Array;

use 5.6.0;

use strict;
use warnings;

our $VERSION = '0.99_03';

# This is to allow DBM::Deep::Array to handle negative indices on
# its own. Otherwise, Perl would intercept the call to negative
# indices for us. This was causing bugs for negative index handling.
our $NEGATIVE_INDICES = 1;

use base 'DBM::Deep';

use Scalar::Util ();

sub _get_self {
    eval { local $SIG{'__DIE__'}; tied( @{$_[0]} ) } || $_[0]
}

sub _repr { shift;[ @_ ] }

sub _import {
    my $self = shift;
    my ($struct) = @_;

    eval {
        local $SIG{'__DIE__'};
        $self->push( @$struct );
    }; if ($@) {
        $self->_throw_error("Cannot import: type mismatch");
    }

    return 1;
}
sub TIEARRAY {
    my $class = shift;
    my $args = $class->_get_args( @_ );

    $args->{type} = $class->TYPE_ARRAY;

    return $class->_init($args);
}

sub FETCH {
    my $self = shift->_get_self;
    my ($key) = @_;

    $self->lock( $self->LOCK_SH );

    my $orig_key;
    if ( $key =~ /^-?\d+$/ ) {
        if ( $key < 0 ) {
            $key += $self->FETCHSIZE;
            unless ( $key >= 0 ) {
                $self->unlock;
                return;
            }
        }
        $orig_key = $key;
    }
    else {
        $orig_key = undef;
    }

    my $rv = $self->SUPER::FETCH( $key, $orig_key );

    $self->unlock;

    return $rv;
}

sub STORE {
    my $self = shift->_get_self;
    my ($key, $value) = @_;

    $self->lock( $self->LOCK_EX );

    my $size;
    my $idx_is_numeric;
    if ( $key =~ /^\-?\d+$/ ) {
        $idx_is_numeric = 1;
        if ( $key < 0 ) {
            $size = $self->FETCHSIZE;
            if ( $key + $size < 0 ) {
                die( "Modification of non-creatable array value attempted, subscript $key" );
            }
            $key += $size
        }
    }

    my $rv = $self->SUPER::STORE( $key, $value, ($key eq 'length' ? undef : $key) );

    if ( $idx_is_numeric ) {
        $size = $self->FETCHSIZE unless defined $size;
        if ( $key >= $size ) {
            $self->STORESIZE( $key + 1 );
        }
    }

    $self->unlock;

    return $rv;
}

sub EXISTS {
    my $self = shift->_get_self;
    my ($key) = @_;

    $self->lock( $self->LOCK_SH );

    if ( $key =~ /^\-?\d+$/ ) {
        if ( $key < 0 ) {
            $key += $self->FETCHSIZE;
            unless ( $key >= 0 ) {
                $self->unlock;
                return;
            }
        }
    }

    my $rv = $self->SUPER::EXISTS( $key );

    $self->unlock;

    return $rv;
}

sub DELETE {
    my $self = shift->_get_self;
    my ($key) = @_;

    $self->lock( $self->LOCK_EX );

    my $size = $self->FETCHSIZE;
    if ( $key =~ /^-?\d+$/ ) {
        if ( $key < 0 ) {
            $key += $size;
            unless ( $key >= 0 ) {
                $self->unlock;
                return;
            }
        }
    }

    my $rv = $self->SUPER::DELETE( $key );

    if ($rv && $key == $size - 1) {
        $self->STORESIZE( $key, ($key eq 'length' ? undef : $key) );
    }

    $self->unlock;

    return $rv;
}

sub FETCHSIZE {
    my $self = shift->_get_self;

    $self->lock( $self->LOCK_SH );

    my $SAVE_FILTER = $self->_storage->{filter_fetch_value};
    $self->_storage->{filter_fetch_value} = undef;

    my $packed_size = $self->FETCH('length');

    $self->_storage->{filter_fetch_value} = $SAVE_FILTER;

    $self->unlock;

    if ($packed_size) {
        return int(unpack($self->_engine->{long_pack}, $packed_size));
    }

    return 0;
}

sub STORESIZE {
    my $self = shift->_get_self;
    my ($new_length) = @_;

    $self->lock( $self->LOCK_EX );

    my $SAVE_FILTER = $self->_storage->{filter_store_value};
    $self->_storage->{filter_store_value} = undef;

    my $result = $self->STORE('length', pack($self->_engine->{long_pack}, $new_length), 'length');

    $self->_storage->{filter_store_value} = $SAVE_FILTER;

    $self->unlock;

    return $result;
}

sub POP {
    my $self = shift->_get_self;

    $self->lock( $self->LOCK_EX );

    my $length = $self->FETCHSIZE();

    if ($length) {
        my $content = $self->FETCH( $length - 1 );
        $self->DELETE( $length - 1 );

        $self->unlock;

        return $content;
    }
    else {
        $self->unlock;
        return;
    }
}

sub PUSH {
    my $self = shift->_get_self;

    $self->lock( $self->LOCK_EX );

    my $length = $self->FETCHSIZE();

    while (my $content = shift @_) {
        $self->STORE( $length, $content );
        $length++;
    }

    $self->unlock;

    return $length;
}

sub SHIFT {
    my $self = shift->_get_self;

    $self->lock( $self->LOCK_EX );

    my $length = $self->FETCHSIZE();

    if ($length) {
        my $content = $self->FETCH( 0 );

        for (my $i = 0; $i < $length - 1; $i++) {
            $self->STORE( $i, $self->FETCH($i + 1) );
        }
        $self->DELETE( $length - 1 );

        $self->unlock;

        return $content;
    }
    else {
        $self->unlock;
        return;
    }
}

sub UNSHIFT {
    my $self = shift->_get_self;
    my @new_elements = @_;

    $self->lock( $self->LOCK_EX );

    my $length = $self->FETCHSIZE();
    my $new_size = scalar @new_elements;

    if ($length) {
        for (my $i = $length - 1; $i >= 0; $i--) {
            $self->STORE( $i + $new_size, $self->FETCH($i) );
        }
    }

    for (my $i = 0; $i < $new_size; $i++) {
        $self->STORE( $i, $new_elements[$i] );
    }

    $self->unlock;

    return $length + $new_size;
}

sub SPLICE {
    my $self = shift->_get_self;

    $self->lock( $self->LOCK_EX );

    my $length = $self->FETCHSIZE();

    ##
    # Calculate offset and length of splice
    ##
    my $offset = shift;
    $offset = 0 unless defined $offset;
    if ($offset < 0) { $offset += $length; }

    my $splice_length;
    if (scalar @_) { $splice_length = shift; }
    else { $splice_length = $length - $offset; }
    if ($splice_length < 0) { $splice_length += ($length - $offset); }

    ##
    # Setup array with new elements, and copy out old elements for return
    ##
    my @new_elements = @_;
    my $new_size = scalar @new_elements;

    my @old_elements = map {
        $self->FETCH( $_ )
    } $offset .. ($offset + $splice_length - 1);

    ##
    # Adjust array length, and shift elements to accomodate new section.
    ##
    if ( $new_size != $splice_length ) {
        if ($new_size > $splice_length) {
            for (my $i = $length - 1; $i >= $offset + $splice_length; $i--) {
                $self->STORE( $i + ($new_size - $splice_length), $self->FETCH($i) );
            }
        }
        else {
            for (my $i = $offset + $splice_length; $i < $length; $i++) {
                $self->STORE( $i + ($new_size - $splice_length), $self->FETCH($i) );
            }
            for (my $i = 0; $i < $splice_length - $new_size; $i++) {
                $self->DELETE( $length - 1 );
                $length--;
            }
        }
    }

    ##
    # Insert new elements into array
    ##
    for (my $i = $offset; $i < $offset + $new_size; $i++) {
        $self->STORE( $i, shift @new_elements );
    }

    $self->unlock;

    ##
    # Return deleted section, or last element in scalar context.
    ##
    return wantarray ? @old_elements : $old_elements[-1];
}

# We don't need to define it, yet.
# It will be useful, though, when we split out HASH and ARRAY
sub EXTEND {
    ##
    # Perl will call EXTEND() when the array is likely to grow.
    # We don't care, but include it because it gets called at times.
    ##
}

sub _copy_node {
    my $self = shift;
    my ($db_temp) = @_;

    my $length = $self->length();
    for (my $index = 0; $index < $length; $index++) {
        my $value = $self->get($index);
        $self->_copy_value( \$db_temp->[$index], $value );
    }

    return 1;
}

##
# Public method aliases
##
sub length { (shift)->FETCHSIZE(@_) }
sub pop { (shift)->POP(@_) }
sub push { (shift)->PUSH(@_) }
sub unshift { (shift)->UNSHIFT(@_) }
sub splice { (shift)->SPLICE(@_) }

# This must be last otherwise we have to qualify all other calls to shift
# as calls to CORE::shift
sub shift { (CORE::shift)->SHIFT(@_) }

1;
__END__