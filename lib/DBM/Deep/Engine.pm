package DBM::Deep::Engine;

use strict;

use Fcntl qw( :DEFAULT :flock :seek );

sub open {
    ##
    # Open a fh to the database, create if nonexistent.
    # Make sure file signature matches DBM::Deep spec.
    ##
    my $self = shift;
    my $obj = shift;

    if (defined($obj->_fh)) { $self->close( $obj ); }

    eval {
        local $SIG{'__DIE__'};
        # Theoretically, adding O_BINARY should remove the need for the binmode
        # Of course, testing it is going to be ... interesting.
        my $flags = O_RDWR | O_CREAT | O_BINARY;

        my $fh;
        sysopen( $fh, $obj->_root->{file}, $flags )
            or $fh = undef;
        $obj->_root->{fh} = $fh;
    }; if ($@ ) { $obj->_throw_error( "Received error: $@\n" ); }
    if (! defined($obj->_fh)) {
        return $obj->_throw_error("Cannot sysopen file: " . $obj->_root->{file} . ": $!");
    }

    my $fh = $obj->_fh;

    #XXX Can we remove this by using the right sysopen() flags?
    # Maybe ... q.v. above
    binmode $fh; # for win32

    if ($obj->_root->{autoflush}) {
        my $old = select $fh;
        $|=1;
        select $old;
    }

    seek($fh, 0 + $obj->_root->{file_offset}, SEEK_SET);

    my $signature;
    my $bytes_read = read( $fh, $signature, length(DBM::Deep->SIG_FILE));

    ##
    # File is empty -- write signature and master index
    ##
    if (!$bytes_read) {
        seek($fh, 0 + $obj->_root->{file_offset}, SEEK_SET);
        print( $fh DBM::Deep->SIG_FILE);
        $self->create_tag($obj, $obj->_base_offset, $obj->_type, chr(0) x $DBM::Deep::INDEX_SIZE);

        my $plain_key = "[base]";
        print( $fh pack($DBM::Deep::DATA_LENGTH_PACK, length($plain_key)) . $plain_key );

        # Flush the filehandle
        my $old_fh = select $fh;
        my $old_af = $|; $| = 1; $| = $old_af;
        select $old_fh;

        my @stats = stat($fh);
        $obj->_root->{inode} = $stats[1];
        $obj->_root->{end} = $stats[7];

        return 1;
    }

    ##
    # Check signature was valid
    ##
    unless ($signature eq DBM::Deep->SIG_FILE) {
        $self->close( $obj );
        return $obj->_throw_error("Signature not found -- file is not a Deep DB");
    }

    my @stats = stat($fh);
    $obj->_root->{inode} = $stats[1];
    $obj->_root->{end} = $stats[7];

    ##
    # Get our type from master index signature
    ##
    my $tag = $self->load_tag($obj, $obj->_base_offset);

#XXX We probably also want to store the hash algorithm name and not assume anything
#XXX The cool thing would be to allow a different hashing algorithm at every level

    if (!$tag) {
        return $obj->_throw_error("Corrupted file, no master index record");
    }
    if ($obj->{type} ne $tag->{signature}) {
        return $obj->_throw_error("File type mismatch");
    }

    return 1;
}

sub close {
    my $self = shift;
    my $obj = shift;

    if ( my $fh = $obj->_root->{fh} ) {
        close $fh;
    }
    $obj->_root->{fh} = undef;

    return 1;
}

sub create_tag {
    ##
    # Given offset, signature and content, create tag and write to disk
    ##
    my $self = shift;
    my ($obj, $offset, $sig, $content) = @_;
    my $size = length($content);

    my $fh = $obj->_fh;

    seek($fh, $offset + $obj->_root->{file_offset}, SEEK_SET);
    print( $fh $sig . pack($DBM::Deep::DATA_LENGTH_PACK, $size) . $content );

    if ($offset == $obj->_root->{end}) {
        $obj->_root->{end} += DBM::Deep->SIG_SIZE + $DBM::Deep::DATA_LENGTH_SIZE + $size;
    }

    return {
        signature => $sig,
        size => $size,
        offset => $offset + DBM::Deep->SIG_SIZE + $DBM::Deep::DATA_LENGTH_SIZE,
        content => $content
    };
}

sub load_tag {
    ##
    # Given offset, load single tag and return signature, size and data
    ##
    my $self = shift;
    my ($obj, $offset) = @_;

    my $fh = $obj->_fh;

    seek($fh, $offset + $obj->_root->{file_offset}, SEEK_SET);
    if (eof $fh) { return undef; }

    my $b;
    read( $fh, $b, DBM::Deep->SIG_SIZE + $DBM::Deep::DATA_LENGTH_SIZE );
    my ($sig, $size) = unpack( "A $DBM::Deep::DATA_LENGTH_PACK", $b );

    my $buffer;
    read( $fh, $buffer, $size);

    return {
        signature => $sig,
        size => $size,
        offset => $offset + DBM::Deep->SIG_SIZE + $DBM::Deep::DATA_LENGTH_SIZE,
        content => $buffer
    };
}

sub index_lookup {
    ##
    # Given index tag, lookup single entry in index and return .
    ##
    my $self = shift;
    my ($obj, $tag, $index) = @_;

    my $location = unpack($DBM::Deep::LONG_PACK, substr($tag->{content}, $index * $DBM::Deep::LONG_SIZE, $DBM::Deep::LONG_SIZE) );
    if (!$location) { return; }

    return $self->load_tag( $obj, $location );
}

sub add_bucket {
    ##
    # Adds one key/value pair to bucket list, given offset, MD5 digest of key,
    # plain (undigested) key and value.
    ##
    my $self = shift;
    my ($obj, $tag, $md5, $plain_key, $value) = @_;
    my $keys = $tag->{content};
    my $location = 0;
    my $result = 2;

    my $root = $obj->_root;

    my $is_dbm_deep = eval { local $SIG{'__DIE__'}; $value->isa( 'DBM::Deep' ) };
    my $internal_ref = $is_dbm_deep && ($value->_root eq $root);

    my $fh = $obj->_fh;

    ##
    # Iterate through buckets, seeing if this is a new entry or a replace.
    ##
    for (my $i=0; $i<$DBM::Deep::MAX_BUCKETS; $i++) {
        my $subloc = unpack($DBM::Deep::LONG_PACK, substr($keys, ($i * $DBM::Deep::BUCKET_SIZE) + $DBM::Deep::HASH_SIZE, $DBM::Deep::LONG_SIZE));
        if (!$subloc) {
            ##
            # Found empty bucket (end of list).  Populate and exit loop.
            ##
            $result = 2;

            $location = $internal_ref
                ? $value->_base_offset
                : $root->{end};

            seek($fh, $tag->{offset} + ($i * $DBM::Deep::BUCKET_SIZE) + $root->{file_offset}, SEEK_SET);
            print( $fh $md5 . pack($DBM::Deep::LONG_PACK, $location) );
            last;
        }

        my $key = substr($keys, $i * $DBM::Deep::BUCKET_SIZE, $DBM::Deep::HASH_SIZE);
        if ($md5 eq $key) {
            ##
            # Found existing bucket with same key.  Replace with new value.
            ##
            $result = 1;

            if ($internal_ref) {
                $location = $value->_base_offset;
                seek($fh, $tag->{offset} + ($i * $DBM::Deep::BUCKET_SIZE) + $root->{file_offset}, SEEK_SET);
                print( $fh $md5 . pack($DBM::Deep::LONG_PACK, $location) );
                return $result;
            }

            seek($fh, $subloc + DBM::Deep->SIG_SIZE + $root->{file_offset}, SEEK_SET);
            my $size;
            read( $fh, $size, $DBM::Deep::DATA_LENGTH_SIZE); $size = unpack($DBM::Deep::DATA_LENGTH_PACK, $size);

            ##
            # If value is a hash, array, or raw value with equal or less size, we can
            # reuse the same content area of the database.  Otherwise, we have to create
            # a new content area at the EOF.
            ##
            my $actual_length;
            my $r = Scalar::Util::reftype( $value ) || '';
            if ( $r eq 'HASH' || $r eq 'ARRAY' ) {
                $actual_length = $DBM::Deep::INDEX_SIZE;

                # if autobless is enabled, must also take into consideration
                # the class name, as it is stored along with key/value.
                if ( $root->{autobless} ) {
                    my $value_class = Scalar::Util::blessed($value);
                    if ( defined $value_class && !$value->isa('DBM::Deep') ) {
                        $actual_length += length($value_class);
                    }
                }
            }
            else { $actual_length = length($value); }

            if ($actual_length <= $size) {
                $location = $subloc;
            }
            else {
                $location = $root->{end};
                seek($fh, $tag->{offset} + ($i * $DBM::Deep::BUCKET_SIZE) + $DBM::Deep::HASH_SIZE + $root->{file_offset}, SEEK_SET);
                print( $fh pack($DBM::Deep::LONG_PACK, $location) );
            }

            last;
        }
    }

    ##
    # If this is an internal reference, return now.
    # No need to write value or plain key
    ##
    if ($internal_ref) {
        return $result;
    }

    ##
    # If bucket didn't fit into list, split into a new index level
    ##
    if (!$location) {
        seek($fh, $tag->{ref_loc} + $root->{file_offset}, SEEK_SET);
        print( $fh pack($DBM::Deep::LONG_PACK, $root->{end}) );

        my $index_tag = $self->create_tag($obj, $root->{end}, DBM::Deep->SIG_INDEX, chr(0) x $DBM::Deep::INDEX_SIZE);
        my @offsets = ();

        $keys .= $md5 . pack($DBM::Deep::LONG_PACK, 0);

        for (my $i=0; $i<=$DBM::Deep::MAX_BUCKETS; $i++) {
            my $key = substr($keys, $i * $DBM::Deep::BUCKET_SIZE, $DBM::Deep::HASH_SIZE);
            if ($key) {
                my $old_subloc = unpack($DBM::Deep::LONG_PACK, substr($keys, ($i * $DBM::Deep::BUCKET_SIZE) +
                        $DBM::Deep::HASH_SIZE, $DBM::Deep::LONG_SIZE));
                my $num = ord(substr($key, $tag->{ch} + 1, 1));

                if ($offsets[$num]) {
                    my $offset = $offsets[$num] + DBM::Deep->SIG_SIZE + $DBM::Deep::DATA_LENGTH_SIZE;
                    seek($fh, $offset + $root->{file_offset}, SEEK_SET);
                    my $subkeys;
                    read( $fh, $subkeys, $DBM::Deep::BUCKET_LIST_SIZE);

                    for (my $k=0; $k<$DBM::Deep::MAX_BUCKETS; $k++) {
                        my $subloc = unpack($DBM::Deep::LONG_PACK, substr($subkeys, ($k * $DBM::Deep::BUCKET_SIZE) +
                                $DBM::Deep::HASH_SIZE, $DBM::Deep::LONG_SIZE));
                        if (!$subloc) {
                            seek($fh, $offset + ($k * $DBM::Deep::BUCKET_SIZE) + $root->{file_offset}, SEEK_SET);
                            print( $fh $key . pack($DBM::Deep::LONG_PACK, $old_subloc || $root->{end}) );
                            last;
                        }
                    } # k loop
                }
                else {
                    $offsets[$num] = $root->{end};
                    seek($fh, $index_tag->{offset} + ($num * $DBM::Deep::LONG_SIZE) + $root->{file_offset}, SEEK_SET);
                    print( $fh pack($DBM::Deep::LONG_PACK, $root->{end}) );

                    my $blist_tag = $self->create_tag($obj, $root->{end}, DBM::Deep->SIG_BLIST, chr(0) x $DBM::Deep::BUCKET_LIST_SIZE);

                    seek($fh, $blist_tag->{offset} + $root->{file_offset}, SEEK_SET);
                    print( $fh $key . pack($DBM::Deep::LONG_PACK, $old_subloc || $root->{end}) );
                }
            } # key is real
        } # i loop

        $location ||= $root->{end};
    } # re-index bucket list

    ##
    # Seek to content area and store signature, value and plaintext key
    ##
    if ($location) {
        my $content_length;
        seek($fh, $location + $root->{file_offset}, SEEK_SET);

        ##
        # Write signature based on content type, set content length and write actual value.
        ##
        my $r = Scalar::Util::reftype($value) || '';
        if ($r eq 'HASH') {
            print( $fh DBM::Deep->TYPE_HASH );
            print( $fh pack($DBM::Deep::DATA_LENGTH_PACK, $DBM::Deep::INDEX_SIZE) . chr(0) x $DBM::Deep::INDEX_SIZE );
            $content_length = $DBM::Deep::INDEX_SIZE;
        }
        elsif ($r eq 'ARRAY') {
            print( $fh DBM::Deep->TYPE_ARRAY );
            print( $fh pack($DBM::Deep::DATA_LENGTH_PACK, $DBM::Deep::INDEX_SIZE) . chr(0) x $DBM::Deep::INDEX_SIZE );
            $content_length = $DBM::Deep::INDEX_SIZE;
        }
        elsif (!defined($value)) {
            print( $fh DBM::Deep->SIG_NULL );
            print( $fh pack($DBM::Deep::DATA_LENGTH_PACK, 0) );
            $content_length = 0;
        }
        else {
            print( $fh DBM::Deep->SIG_DATA );
            print( $fh pack($DBM::Deep::DATA_LENGTH_PACK, length($value)) . $value );
            $content_length = length($value);
        }

        ##
        # Plain key is stored AFTER value, as keys are typically fetched less often.
        ##
        print( $fh pack($DBM::Deep::DATA_LENGTH_PACK, length($plain_key)) . $plain_key );

        ##
        # If value is blessed, preserve class name
        ##
        if ( $root->{autobless} ) {
            my $value_class = Scalar::Util::blessed($value);
            if ( defined $value_class && $value_class ne 'DBM::Deep' ) {
                ##
                # Blessed ref -- will restore later
                ##
                print( $fh chr(1) );
                print( $fh pack($DBM::Deep::DATA_LENGTH_PACK, length($value_class)) . $value_class );
                $content_length += 1;
                $content_length += $DBM::Deep::DATA_LENGTH_SIZE + length($value_class);
            }
            else {
                print( $fh chr(0) );
                $content_length += 1;
            }
        }

        ##
        # If this is a new content area, advance EOF counter
        ##
        if ($location == $root->{end}) {
            $root->{end} += DBM::Deep->SIG_SIZE;
            $root->{end} += $DBM::Deep::DATA_LENGTH_SIZE + $content_length;
            $root->{end} += $DBM::Deep::DATA_LENGTH_SIZE + length($plain_key);
        }

        ##
        # If content is a hash or array, create new child DBM::Deep object and
        # pass each key or element to it.
        ##
        if ($r eq 'HASH') {
            my $branch = DBM::Deep->new(
                type => DBM::Deep->TYPE_HASH,
                base_offset => $location,
                root => $root,
            );
            foreach my $key (keys %{$value}) {
                $branch->STORE( $key, $value->{$key} );
            }
        }
        elsif ($r eq 'ARRAY') {
            my $branch = DBM::Deep->new(
                type => DBM::Deep->TYPE_ARRAY,
                base_offset => $location,
                root => $root,
            );
            my $index = 0;
            foreach my $element (@{$value}) {
                $branch->STORE( $index, $element );
                $index++;
            }
        }

        return $result;
    }

    return $obj->_throw_error("Fatal error: indexing failed -- possibly due to corruption in file");
}

1;
__END__
