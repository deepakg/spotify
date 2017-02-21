use strict;
use warnings;

use 5.14.1;

use Config::INI::Reader;
use Data::Dumper;
use File::Spec;
use File::Temp qw(tempdir tempfile);
use Getopt::Long;
use HTTP::Tiny;
use Imager::Montage;
use JSON::XS qw(decode_json);
use List::Util qw(uniq shuffle);

my $image_urls = get_images();
# say Dumper($images);
my $dir = download_images($image_urls);
create_montage($dir);

sub get_images {
    my $playlist_url = "https://open.spotify.com/user/deepak.gulati/playlist/7EhvGQRwc71oEpRjvEV6uR";
    GetOptions("playlist=s" => \$playlist_url);
    my ($user_id, $playlist_id) = $playlist_url =~ m|^https://open\.spotify\.com/user/(.*?)/playlist/(.*)$|;
    my $api_url = "https://api.spotify.com/v1/users/$user_id/playlists/$playlist_id/tracks";

    my @items;
    my $token = get_bearer_token();

    my $ua = HTTP::Tiny->new;
    my $options = {
        headers => {
            Authorization => $token->{token_type} . ' ' . $token->{access_token},
        }
    };
    my $page = 1;

    while ($api_url) {
        say STDERR "Fetching page: $page";
        my $resp = $ua->get($api_url, $options);
        if ($resp->{success}) {
            my $tracks = decode_json($resp->{content});
            push @items, @{$tracks->{items}};
            $api_url = $tracks->{next};
        }
        else {
            die Dumper($resp);
        }
        $page++;
    }

    # extract image urls from items. we get 3 images from spotify, the
    # first one is the largest (640px) and we'll download that
    my @images;
    for my $item (@items) {
        push @images, $item->{track}{album}{images}[0]{url};
    }

    # some tracks could be from the same album and will thus have same
    # album art urls. so we de-duplicate the array.
    @images = uniq(@images);
    @images = grep { defined $_ } @images; #we could get undef urls from spotify

    say STDERR "Found " . scalar(@items) . " tracks from " . scalar(@images) . " unique albums with album art.";
    return \@images;
}

# download the images to the specified folder and return the path to it to the caller
sub download_images {
    my $images = shift;
    my $dir = tempdir(
        CLEANUP => 1,
        DIR => File::Spec->tmpdir,
        template => 'spotify-montage-XXXX',
    );
    say STDERR $dir;
    my $count = 1;
    my $total = scalar(@$images);
    my $ua = HTTP::Tiny->new;
    for my $image (@$images) {
        # $image is the full url - split it on '/' to get the name of the file
        # $image: 'https://i.scdn.co/image/3c101e331e5383e70b523f8578b82362405291ed'
        # $file: X-3c101e331e5383e70b523f8578b82362405291ed where X = $count
        my $file = $count . '-' . (split m|/|, $image)[-1] . '.jpg';

        # download the file
        say STDERR "Downloading $count of $total";
        $ua->mirror($image, $dir . "/" . $file);
        $count++;
    }
    return $dir;
}

sub create_montage {
    my $dir = shift;

    my @images = glob($dir . "/" . "*.jpg");
    @images = map { $_->[0] } # retrieve the full path
        sort { $a->[-1] <=> $b->[-1] } # sort on prefix
        map {
            my $filename = (split(/\//, $_))[-1]; # split the path on '/', the last value in the resulting array is the filename
            my $prefix = (split(/\-/,$filename))[0]; # filenames look like
            # 8-76ee89c0e075a2f85a587584f9ae129dfca13dbb.jpg so
            # splitting on '-' and taking the first element gives us
            # the numeric prefix
        [$_, $prefix]; #return the full path + prefix so that we can sort the path by prefix
    } @images;

    # say Dumper(\@images);
    # calclulate the rows and columns so that the montage is in 4:3 ratio
    my $total_images = scalar @images;
    my ($rows, $cols) = get_rows_cols($total_images);
    say STDERR "Filling $total_images images into a collage of $rows rows and $cols columns";

    my $im = Imager::Montage->new;
    my $page = $im->gen_page(
        {
            files      => \@images,
            geometry_w => 200,
            geometry_h => 200,
            resize_w   => 200,
            resize_h   => 200,
            cols       => $cols,
            rows       => $rows,
        }
    );

    my ($fh, $outfile) = tempfile('spotify-montage-XXXX', SUFFIX => '.png');
    $page->write(file => $outfile, type => 'png');
    say "Montage written to ./$outfile";
}

sub get_bearer_token {
    my ($client_id, $client_secret) = get_api_tokens();
    my $ua = HTTP::Tiny->new;
    say STDERR "Fetching bearer token";
    my $resp = $ua->post_form(
        "https://accounts.spotify.com/api/token",
        {
            grant_type => 'client_credentials',
            client_id =>  $client_id,
            client_secret => $client_secret,
        },
    );

    my $token;
    if ($resp->{success}) {
        $token = decode_json($resp->{content});
    }
    else {
        die Dumper($resp);
    }

    return $token;
}

sub get_api_tokens {
    my $client_id;
    my $client_secret;

    my $config = $ENV{HOME} . '/.api_keys';
    my $config_hash = Config::INI::Reader->read_file($config);

    if ($config_hash && exists $config_hash->{spotify}) {
        if (exists $config_hash->{spotify}{client_id}) {
            $client_id = $config_hash->{spotify}{client_id};
        }

        if (exists $config_hash->{spotify}{client_secret}) {
            $client_secret = $config_hash->{spotify}{client_secret};
        }
    }

    return ($client_id, $client_secret);
}

sub get_rows_cols {
    my $total = shift;
    my $cols = int(sqrt($total/12) * 4);
    my $rows = int(sqrt($total/12) * 3);

    if ($rows * $cols > $total) {
        $cols--;
    }

    elsif ($rows * $cols < $total) {
        $cols++;
        if ($rows * $cols > $total) {
            $cols--;
        }
    }

    if ($cols == 0) {
        $cols = 1;
    }

    return($rows, $cols);
}
