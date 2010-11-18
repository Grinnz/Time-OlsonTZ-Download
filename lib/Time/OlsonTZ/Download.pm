=head1 NAME

Time::OlsonTZ::Download - Olson timezone database from source

=head1 SYNOPSIS

	use Time::OlsonTZ::Download;

	$version = Time::OlsonTZ::Download->latest_version;

	$download = Time::OlsonTZ::Download->new;

	$version = $download->version;
	$dir = $download->dir;
	$dir = $download->unpacked_dir;

	$names = $download->canonical_names;
	$names = $download->link_names;
	$names = $download->all_names;
	$links = $download->raw_links;
	$links = $download->threaded_links;
	$countries = $download->country_selection;

	$files = $download->data_files;
	$zic = $download->zic_exe;
	$dir = $download->zoneinfo_dir;

=head1 DESCRIPTION

An object of this class represents a local copy of the source of
the Olson timezone database, possibly used to build binary tzfiles.
The source copy always begins by being downloaded from the canonical
repository of the Olson database.  This class provides methods to help
with extracting useful information from the source.

=cut

package Time::OlsonTZ::Download;

{ use 5.006; }
use warnings;
use strict;

use Carp qw(croak);
use File::Path 2.07 qw(rmtree);
use File::Temp 0.22 qw(tempdir);
use HTTP::Lite 2.2 ();
use IO::Dir 1.03 ();
use IO::File 1.03 ();
use IPC::Filter 0.002 qw(filter);
use Net::FTP 1.21 ();
use Params::Classify 0.000 qw(is_undef is_string);
use String::ShellQuote 1.01 qw(shell_quote);

our $VERSION = "0.001";

sub _elsie_ftp() {
	my $ftp = Net::FTP->new("elsie.nci.nih.gov")
		or die "FTP error: $@\n";
	$ftp->login("anonymous","-anonymous\@")
		or die "FTP error: ".$ftp->message;
	$ftp->binary
		or die "FTP error: ".$ftp->message;
	$ftp->cwd("pub")
		or die "FTP error: ".$ftp->message;
	return $ftp;
}

sub _all_versions($) {
	my($ftp) = @_;
	my $filenames = $ftp->ls
		or die "FTP error: ".$ftp->message;
	my(%cversions, %dversions);
	foreach(@$filenames) {
		if(/\Atzcode([0-9]{4}[a-z])\.tar\.gz\z/) {
			$cversions{$1} = undef;
		}
		if(/\Atzdata([0-9]{4}[a-z])\.tar\.gz\z/) {
			$dversions{$1} = undef;
		}
	}
	die "no timezone database found on server\n"
		unless scalar(keys(%cversions)) && scalar(keys(%dversions));
	return (\%cversions, \%dversions);
}

sub _latest_version($) {
	my($dversions) = @_;
	my $latest = "";
	foreach(keys %$dversions) {
		$latest = $_ if $_ gt $latest;
	}
	return $latest;
}

sub _icu_download($$) {
	my($remname, $locname) = @_;
	my $locfh = IO::File->new($locname, "w")
		or die "file $locname unwritable: $!\n";
	my $http = HTTP::Lite->new;
	$http->http11_mode(1);
	my $res = $http->request("http://source.icu-project.org/repos/icu".
			"/data/trunk/tzdata/mirror/$remname", sub {
		local $\ = undef;
		$locfh->print(${$_[1]}) or die "file $locname unwritable: $!\n";
		return undef;
	});
	$locfh->flush or die "file $locname unwritable: $!\n";
	defined $res or die "HTTP I/O error on $remname\n";
	unless($res == 200) {
		my $msg = $http->status_message;
		$msg =~ s/[\r\n]//g;
		die "HTTP $res $msg on $remname\n";
	}
}

=head1 CLASS METHODS

=over

=item Time::OlsonTZ::Download->latest_version

Returns the version number of the latest available version of the Olson
timezone database.  This requires consulting the repository, but is much
cheaper than actually downloading the database.

=cut

sub latest_version {
	my($class) = @_;
	croak "@{[__PACKAGE__]}->latest_version not called as a class method"
		unless is_string($class);
	my(undef, $dversions) = _all_versions(_elsie_ftp());
	return _latest_version($dversions);
}

=back

=cut

sub DESTROY {
	my($self) = @_;
	local($., $@, $!, $^E, $?);
	rmtree($self->{dir}, 0, 0) if exists $self->{dir};
}

=head1 CONSTRUCTOR

=over

=item Time::OlsonTZ::Download->new([VERSION])

Downloads a copy of the source of the Olson database, and returns an
object representing that copy.

I<VERSION>, if supplied, is a version number specifying which version of
the database is to be downloaded.  If not supplied, the latest available
version will be downloaded.  Version numbers for the Olson database
currently consist of a year number and a lowercase letter, such as
"C<2010k>".  Availability of versions other than the latest is limited:
there appears to be no official archive, so this module is at the mercy
of mirror administrators' whims.

=cut

sub new {
	my($class, $version) = @_;
	die "malformed Olson version number `$version'\n"
		unless is_undef($version) ||
			(is_string($version) &&
				$version =~ /\A[0-9]{4}[a-z]\z/);
	my $ftp = _elsie_ftp();
	my($cversions, $dversions) = _all_versions($ftp);
	my $latest_version = _latest_version($dversions);
	$version ||= $latest_version;
	$version le $latest_version
		or die "Olson DB version $version doesn't exist yet\n";
	my $self = bless({}, $class);
	$self->{version} = $version;
	$self->{dir} = tempdir();
	if(exists $dversions->{$version}) {
		my @cversions = sort { $b cmp $a } grep { $_ le $version }
			keys %$cversions;
		die "no matching code available for data version $version\n"
			unless @cversions;
		my $cversion = $cversions[0];
		$ftp->get("tzcode$cversion.tar.gz", $self->dir."/tzcode.tar.gz")
			or die "FTP error on tzcode$cversion.tar.gz: ".
				$ftp->message;
		$ftp->get("tzdata$version.tar.gz", $self->dir."/tzdata.tar.gz")
			or die "FTP error on tzdata$version.tar.gz: ".
				$ftp->message;
	} else {
		$ftp = undef;
		foreach my $part (qw(tzcode tzdata)) {
			my $remname = "$part$version.tar.gz";
			my $locname = $self->dir."/$part.tar.gz";
			_icu_download($remname, $locname);
		}
	}
	$self->{downloaded} = 1;
	return $self;
}

=back

=head1 METHODS

=head2 Basic information

=over

=item $download->version

Returns the version number of the database of which a copy is represented
by this object.

=cut

sub version {
	my($self) = @_;
	die "Olson database version not determined\n"
		unless exists $self->{version};
	return $self->{version};
}

=item $download->dir

Returns the pathname of the directory in which the files of this download
are located.  With this method, there is no guarantee of particular
files being available in the directory; see other directory-related
methods below that establish particular directory contents.

The directory does not move during the lifetime of the download object:
this method will always return the same pathname.  The directory and
all of its contents, including subdirectories, will be automatically
deleted when this object is destroyed.  This will be when the main
program terminates, if it is not otherwise destroyed.  Any files that
it is desired to keep must be copied to a permanent location.

=cut

sub dir {
	my($self) = @_;
	die "download directory not created\n"
		unless exists $self->{dir};
	return $self->{dir};
}

sub _ensure_downloaded {
	my($self) = @_;
	die "can't use download because downloading failed\n"
		unless $self->{downloaded};
}

sub _ensure_unpacked {
	my($self) = @_;
	unless($self->{unpacked}) {
		$self->_ensure_downloaded;
		foreach my $part (qw(tzcode tzdata)) {
			filter("", "cd @{[shell_quote($self->dir)]} && ".
					"gunzip < $part.tar.gz | tar xf -");
		}
		$self->{unpacked} = 1;
	}
}

=item $download->unpacked_dir

Returns the pathname of the directory in which the downloaded source
files have been unpacked.  This is the local temporary directory used
by this download.  This method will unpack the files there if they have
not already been unpacked.

=cut

sub unpacked_dir {
	my($self) = @_;
	$self->_ensure_unpacked;
	return $self->dir;
}

=back

=head2 Zone metadata

=over

=cut

sub _ensure_canonnames_and_rawlinks {
	my($self) = @_;
	unless(exists $self->{canonical_names}) {
		my %seen;
		my %canonnames;
		my %rawlinks;
		foreach(@{$self->data_files}) {
			my $fh = IO::File->new($_, "r")
				or die "data file $_ unreadable: $!\n";
			local $/ = "\n";
			while(defined(my $line = $fh->getline)) {
				if($line =~ /\AZone[ \t]+([!-~]+)[ \t\n]/) {
					my $name = $1;
					die "zone $name multiply defined\n"
						if exists $seen{$name};
					$seen{$name} = undef;
					$canonnames{$name} = undef;
				} elsif($line =~ /\ALink[\ \t]+
						([!-~]+)[\ \t]+
						([!-~]+)[\ \t\n]/x) {
					my($target, $name) = ($1, $2);
					die "zone $name multiply defined\n"
						if exists $seen{$name};
					$seen{$name} = undef;
					$rawlinks{$name} = $target;
				}
			}
		}
		$self->{raw_links} = \%rawlinks;
		$self->{canonical_names} = \%canonnames;
	}
}

=item $download->canonical_names

Returns the set of timezone names that this version of the database
defines as canonical.  These are the timezone names that are directly
associated with a set of observance data.  The return value is a reference
to a hash, in which the keys are the canonical timezone names and the
values are all C<undef>.

=cut

sub canonical_names {
	my($self) = @_;
	$self->_ensure_canonnames_and_rawlinks;
	return $self->{canonical_names};
}

=item $download->link_names

Returns the set of timezone names that this version of the database
defines as links.  These are the timezone names that are aliases for
other names.  The return value is a reference to a hash, in which the
keys are the link timezone names and the values are all C<undef>.

=cut

sub link_names {
	my($self) = @_;
	unless(exists $self->{link_names}) {
		$self->{link_names} =
			{ map { ($_ => undef) } keys %{$self->raw_links} };
	}
	return $self->{link_names};
}

=item $download->all_names

Returns the set of timezone names that this version of the database
defines.  These are the L</canonical_names> and the L</link_names>.
The return value is a reference to a hash, in which the keys are the
timezone names and the values are all C<undef>.

=cut

sub all_names {
	my($self) = @_;
	unless(exists $self->{all_names}) {
		$self->{all_names} = {
			%{$self->canonical_names},
			%{$self->link_names},
		};
	}
	return $self->{all_names};
}

=item $download->raw_links

Returns details of the timezone name links in this version of the
database.  Each link defines one timezone name as an alias for some
other timezone name.  The return value is a reference to a hash, in
which the keys are the aliases and each value is the preferred timezone
name to which that alias directly refers.  It is possible for an alias
to point to another alias, or to point to a non-existent name.  For a
more processed view of links, see L</threaded_links>.

=cut

sub raw_links {
	my($self) = @_;
	$self->_ensure_canonnames_and_rawlinks;
	return $self->{raw_links};
}

=item $download->threaded_links

Returns details of the timezone name links in this version of the
database.  Each link defines one timezone name as an alias for some
other timezone name.  The return value is a reference to a hash, in
which the keys are the aliases and each value is the canonical name of
the timezone to which that alias refers.  All such canonical names can
be found in the L</canonical_names> hash.

=cut

sub threaded_links {
	my($self) = @_;
	unless(exists $self->{threaded_links}) {
		my $raw_links = $self->raw_links;
		my %links = %$raw_links;
		while(1) {
			my $done_any;
			foreach(keys %links) {
				next unless exists $raw_links->{$links{$_}};
				$links{$_} = $raw_links->{$links{$_}};
				die "circular link at $_\n" if $links{$_} eq $_;
				$done_any = 1;
			}
			last unless $done_any;
		}
		my $canonical_names = $self->canonical_names;
		foreach(keys %links) {
			die "link from $_ to non-existent zone $links{$_}\n"
				unless exists $canonical_names->{$links{$_}};
		}
		$self->{threaded_links} = \%links;
	}
	return $self->{threaded_links};
}

=item $download->country_selection

Returns information about how timezones relate to countries, intended
to aid humans in selecting a geographical timezone.  This information
is derived from the C<zone.tab> and C<iso3166.tab> files in the database
source.

The return value is a reference to a hash, keyed by (ISO 3166 alpha-2
uppercase) country code.  The value for each country is a hash containing
these values:

=over

=item B<alpha2_code>

The ISO 3166 alpha-2 uppercase country code.

=item B<olson_name>

An English name for the country, possibly in a modified form, optimised
to help humans find the right entry in alphabetical lists.  This is
not necessarily identical to the country's standard short or long name.
(For other forms of the name, consult a database of countries, keying
by the country code.)

=item B<regions>

Information about the regions of the country that use distinct
timezones.  This is a hash, keyed by English description of the region.
The description is empty if there is only one region.  The value for
each region is a hash containing these values:

=over

=item B<olson_description>

Brief English description of the region, used to distinguish between
the regions of a single country.  Empty string if the country has only
one region for timezone purposes.  (This is the same string used as the
key in the B<regions> hash.)

=item B<timezone_name>

Name of the Olson timezone used in this region.  This is not necessarily
a canonical name (it may be a link).  Typically, where there are aliases
or identical canonical zones, a name is chosen that refers to a location
in the country of interest.  It is not guaranteed that the named timezone
exists in the database (though it always should).

=item B<location_coords>

Geographical coordinates of some point within the location referred to in
the timezone name.  This is a latitude and longitude, in ISO 6709 format.

=back

=back

This data structure is intended to help a human select the appropriate
timezone based on political geography, specifically working from a
selection of country.  It is of essentially no use for any other purpose.
It is not strictly guaranteed that every geographical timezone in the
database is listed somewhere in this structure, so it is of limited use
in providing information about an already-selected timezone.  It does
not include non-geographic timezones at all.  It also does not claim
to be a comprehensive list of countries, and does not make any claims
regarding the political status of any entity listed: the "country"
classification is loose, and used only for identification purposes.

=cut

sub country_selection {
	my($self) = @_;
	unless(exists $self->{country_selection}) {
		my $itabname = $self->unpacked_dir."/iso3166.tab";
		my $ztabname = $self->unpacked_dir."/zone.tab";
		local $/ = "\n";
		my %itab;
		my $itabfh = IO::File->new($itabname, "r")
			or die "data file $itabname unreadable: $!\n";
		while(defined(my $line = $itabfh->getline)) {
			if($line =~ /\A([A-Z]{2})\t([!-~][ -~]*[!-~])\n\z/) {
				die "duplicate $itabname entry for $1\n"
					if exists $itab{$1};
				$itab{$1} = $2;
			} elsif($line !~ /\A#[^\n]*\n\z/) {
				die "bad line in $itabname\n";
			}
		}
		my %sel;
		my $ztabfh = IO::File->new($ztabname, "r")
			or die "data file $ztabname unreadable: $!\n";
		while(defined(my $line = $ztabfh->getline)) {
			if($line =~ /\A([A-Z]{2})
				\t([-+][0-9]{4}(?:[0-9]{2})?
					[-+][0-9]{5}(?:[0-9]{2})?)
				\t([!-~]+)
				(?:\t([!-~][ -~]*[!-~]))?
			\n\z/x) {
				my($cc, $coord, $zn, $reg) = ($1, $2, $3, $4);
				$reg = "" unless defined $reg;
				$sel{$cc} ||= { regions => {} };
				die "duplicate $ztabname entry for $cc\n"
					if exists $sel{$cc}->{regions}->{$reg};
				$sel{$cc}->{regions}->{$reg} = {
					olson_description => $reg,
					timezone_name => $zn,
					location_coords => $coord,
				};
			} elsif($line !~ /\A#[^\n]*\n\z/) {
				die "bad line in $ztabname\n";
			}
		}
		foreach(keys %sel) {
			die "unknown country $_\n" unless exists $itab{$_};
			$sel{$_}->{alpha2_code} = $_;
			$sel{$_}->{olson_name} = $itab{$_};
			die "bad region description in $_\n"
				if keys(%{$sel{$_}->{regions}}) == 1 xor
					exists($sel{$_}->{regions}->{""});
		}
		$self->{country_selection} = \%sel;
	}
	return $self->{country_selection};
}

=back

=head2 Compiling zone data

=over

=item $download->data_files

Returns a reference to an array containing the pathnames of all the
source data files in the database.  These are located in the local
temporary directory used by this download.

There is approximately one source data file per continent.  Each data
file, in a human-editable textual format, describes the known civil
timezones used on the file's continent.  The textual format is not
standardised, and is peculiar to the Olson database, so parsing it
directly is in principle a dubious proposition, but in practice it is
very stable.

=cut

sub _ensure_standard_zonenames {
	my($self) = @_;
	unless(exists $self->{standard_zonenames}) {
		$self->_ensure_unpacked;
		my $mf = IO::File->new($self->dir."/Makefile", "r");
		my $mfc = $mf ? do { local $/ = undef; $mf->getline } : "";
		$self->{standard_zonenames} = !!($mfc =~ m#
			\nzonenames:[\ \t]+\$\(TDATA\)[\ \t]*\n
			\t[\ \t]*\@\$\(AWK\)\ '
			/\^Zone/\ \{\ print\ \$\$2\ \}
			\ /\^Link/\ {\ print\ \$\$3\ }
			'\ \$\(TDATA\)[\ \t]*\n\n
		#x);
	}
	die "format of zone name declarations is not what this code expects"
		unless $self->{standard_zonenames};
}

sub data_files {
	my($self) = @_;
	unless(exists $self->{data_files}) {
		$self->_ensure_standard_zonenames;
		$self->_ensure_unpacked;
		my $list = filter("", "cd @{[shell_quote($self->dir)]} && ".
					"make zonenames AWK=echo");
		$list =~ s#\A.*\{.*\} ##s;
		$list =~ s#\n\z##;
		$self->{data_files} =
			[ map { $self->dir."/".$_ } split(/ /, $list) ];
	}
	return $self->{data_files};
}

sub _ensure_zic_built {
	my($self) = @_;
	unless($self->{zic_built}) {
		$self->_ensure_unpacked;
		filter("", "cd @{[shell_quote($self->dir)]} && make zic");
		$self->{zic_built} = 1;
	}
}

=item $download->zic_exe

Returns the pathname of the C<zic> executable that has been built from
the downloaded source.  This is located in the local temporary directory
used by this download.  This method will build C<zic> if it has not
already been built.

=cut

sub zic_exe {
	my($self) = @_;
	$self->_ensure_zic_built;
	return $self->dir."/zic";
}

=item $download->zoneinfo_dir([OPTIONS])

Returns the pathname of the directory containing binary tzfiles (in
L<tzfile(5)> format) that have been generated from the downloaded source.
This is located in the local temporary directory used by this download,
and the files within it have names that match the timezone names (as
returned by L</all_names>).  This method will generate the tzfiles if
they have not already been generated.

The optional parameter I<OPTIONS> controls which kind of tzfiles are
desired.  If supplied, it must be a reference to a hash, in which these
keys are permitted:

=over

=item B<leaps>

Truth value, controls whether the tzfiles incorporate information about
known leap seconds offsets that account for the known leap seconds.
If false (which is the default), the tzfiles have no knowledge of leap
seconds, and are intended to be used on a system where C<time_t> is some
flavour of UT (as is conventional on Unix and is the POSIX standard).
If true, the tzfiles know about leap seconds that have occurred between
1972 and the date of the database, and are intended to be used on a
system where C<time_t> is (from 1972 onwards) a linear count of TAI
seconds (which is a non-standard arrangement).

=back

=cut

sub _foreach_nondir_under($$);
sub _foreach_nondir_under($$) {
	my($dir, $callback) = @_;
	my $dh = IO::Dir->new($dir) or die "can't examine $dir: $!\n";
	while(defined(my $ent = $dh->read)) {
		next if $ent =~ /\A\.\.?\z/;
		my $entpath = $dir."/".$ent;
		if(-d $entpath) {
			_foreach_nondir_under($entpath, $callback);
		} else {
			$callback->($entpath);
		}
	}
}

sub zoneinfo_dir {
	my($self, $options) = @_;
	$options = {} if is_undef($options);
	foreach(keys %$options) {
		die "bad option `$_'\n" unless /\Aleaps\z/;
	}
	my $type = $options->{leaps} ? "right" : "posix";
	my $zidir = $self->dir."/zoneinfo_$type";
	unless($self->{"zoneinfo_built_$type"}) {
		filter("", "cd @{[shell_quote($self->unpacked_dir)]} && ".
			"make ${type}_only TZDIR=@{[shell_quote($zidir)]}");
		my %expect_names = %{$self->all_names};
		my $skiplen = length($zidir) + 1;
		_foreach_nondir_under($zidir, sub {
			my($fname) = @_;
			my $lname = substr($fname, $skiplen);
			unless(exists $expect_names{$lname}) {
				die "unexpected file $lname\n";
			}
			delete $expect_names{$lname};
		});
		if(keys %expect_names) {
			die "missing file @{[(sort keys %expect_names)[0]]}\n";
		}
		$self->{"zoneinfo_built_$type"} = 1;
	}
	return $zidir;
}

=back

=head1 BUGS

Most of what this class does will only work on Unix platforms.  This is
largely because the Olson database source is heavily Unix-oriented.

It also won't be much good if you're not connected to the Internet.

This class is liable to break if the format of the Olson database source
ever changes substantially.  If that happens, an update of this class
will be required.  It should at least recognise that it can't perform,
rather than do the wrong thing.

=head1 SEE ALSO

L<DateTime::TimeZone::Tzfile>,
L<Time::OlsonTZ::Data>,
L<tzfile(5)>

=head1 AUTHOR

Andrew Main (Zefram) <zefram@fysh.org>

=head1 COPYRIGHT

Copyright (C) 2010 Andrew Main (Zefram) <zefram@fysh.org>

=head1 LICENSE

This module is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1;
