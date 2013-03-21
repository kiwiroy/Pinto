# ABSTRACT: Extract packages provided/required by a distribution archive

package Pinto::PackageExtractor;

use Moose;
use MooseX::StrictConstructor;
use MooseX::Types::Moose qw(HashRef Bool);
use MooseX::MarkAsMethods (autoclean => 1);

use Try::Tiny;
use Dist::Metadata;
use Path::Class qw(dir);
use File::Temp qw(tempdir);
use Archive::Extract;

use Pinto::Types qw(File Dir);
use Pinto::Util qw(debug throw);

#-----------------------------------------------------------------------------

# VERSION

#-----------------------------------------------------------------------------

has archive => (
    is       => 'ro',
    isa      => File,
    required => 1,
    coerce   => 1,
);


has dist_dir => (
    is       => 'ro',
    isa      => Dir,
    default  => sub { 
                       my $self = shift;
                       my $dist = $self->archive;
                       my $work_dir = dir(tempdir(CLEANUP => 1));
                       local $Archive::Extract::PREFER_BIN = 1;
                       my $ae = Archive::Extract->new( archive => $dist );
                       $ae->extract(to => $work_dir) or croak $ae->error;

                       my @children = $work_dir->children;
                       return @children == 1 ? $children[0] : $work_dir;
                    },
    init_arg => undef,
    lazy     => 1,
);


has dm => (
    is       => 'ro',
    isa      => 'Dist::Metadata',
    default  => sub { Dist::Metadata->new(dir => $_[0]->dist_dir) },
    init_arg => undef,
    lazy     => 1,
);

#-----------------------------------------------------------------------------

sub provides {
    my ($self) = @_;

    my $archive = $self->archive;
    debug("Extracting packages provided by archive $archive");

    my $mod_info =   try { $self->dm->module_info( {checksum => 'sha256'} )     }
                   catch { throw "Unable to extract packages from $archive: $_" };

    my @provides;
    for my $pkg_name ( sort keys %{ $mod_info } ) {

        my $info = $mod_info->{$pkg_name};
        my $pkg_ver = version->parse( $info->{version} );
        debug("Archive $archive provides: $pkg_name-$pkg_ver");

        push @provides, { name => $pkg_name,     version => $pkg_ver, 
                          file => $info->{file}, sha256  => $info->{sha256} };
    }

    @provides = $self->__common_sense_workaround($archive->basename)
      if @provides == 0 and $archive->basename =~ m/^ common-sense /x;

    return @provides;
}

#-----------------------------------------------------------------------------

sub requires {
    my ($self) = @_;

    my $archive = $self->archive;
    debug("Extracting packages required by archive $archive");

    my $prereqs_meta =   try { $self->dm->meta->prereqs }
                       catch { throw "Unable to extract prereqs from $archive: $_" };

    my %prereqs;
    for my $phase ( qw( configure build test runtime ) ) {
        my $p = $prereqs_meta->{$phase} || {};
        %prereqs = ( %prereqs, %{ $p->{requires} || {} } );
    }


    my @prereqs;
    for my $pkg_name (sort keys %prereqs) {

        my $pkg_ver = version->parse( $prereqs{$pkg_name} );

        debug("Archive $archive requires: $pkg_name-$pkg_ver");
        push @prereqs, {name => $pkg_name, version => $pkg_ver};
    }

    return @prereqs;
}

#-----------------------------------------------------------------------------
# HACK: The common-sense distribution generates the .pm file at build time.
# It relies on an unusual feature of PAUSE that scans the __DATA__ section
# of .PM files for potential packages.  Module::Metdata doesn't have that
# feature, so to us, it appears that common-sense contains no packages.
# I've asked the author to use the "provides" field of the META file so
# that other tools can discover the packages in his distribution, but
# he has refused to do so.  So we work around it by just assuming the
# distribution contains a package named "common::sense".

sub __common_sense_workaround {
    my ($self, $cs_archive) = @_;

    my ($version) = ($cs_archive =~ m/common-sense- ([\d_.]+) \.tar\.gz/x);

    return { name => 'common::sense',
             version => version->parse($version) };
}

#-----------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;

#-----------------------------------------------------------------------------

1;

__END__
