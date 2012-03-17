package Text::Hatena::Embed;
use strict;
use warnings;

use Any::Moose;
extends 'Web::oEmbed';

use Encode;
use JSON::XS;
use Digest::SHA1 qw(sha1_hex);
use Text::MicroTemplate;

has 'cache' => (
    is => 'rw',
    default => sub {
        require Cache::MemoryCache;
        Cache::MemoryCache->new({namespace => __PACKAGE__});
    }
);

has 'lang' => (is => 'rw', default => 'en');

# url => html が API に問い合わせ無くても決まるもの
my $embeds = [
    {
        regexp => qr{https?://gist.github.com/(?<id>\d+)}i,
        format => q{<script src="https://gist.github.com/{{= $id }}.js"> </script>},
    },
    {
        regexp => qr{https?://(?:jp|www)[.]youtube[.]com/watch[?]v=(?<id>[\w\-]+)}i,
        format => q{<iframe width="420" height="315" src="http://www.youtube.com/embed/{{= $id }}?wmode=transparent" frameborder="0" allowfullscreen></iframe>},
    },
    {
        regexp => qr{http://(?<domain>ugomemo[.]hatena[.]ne[.]jp|flipnote[.]hatena[.]com)/(?<did>[0-9A-Fa-f]{16})[@]DSi/movie/(?<file>[0-9A-Za-z_]{10,30})}i,
        format => sub {
            my ($domain, $did, $file) = map { $_[0]->{$_} } qw/domain did file/;
            my $swf = {
                'ugomemo.hatena.ne.jp' => 'http://ugomemo.hatena.ne.jp/js/ugoplayer_s.swf',
                'flipnote.hatena.com' => 'http://flipnote.hatena.com/js/flipplayer_s.swf',
            }->{$domain};
            return sprintf(
                q{<object data="%s" type="application/x-shockwave-flash" width="279" height="240"><param name="movie" value="%s"></param><param name="FlashVars" value="did=%s&file=%s"></param></object>},
                $swf,
                $swf,
                $did,
                $file,
            );
        }
    },
    {
        regexp => qr{http://www.nicovideo.jp/watch/(?<vid>\w+)}i,
        format => q{<script type="text/javascript" src="http://ext.nicovideo.jp/thumb_watch/{{= $vid }}"></script>},
    },

];

# oEmbed 対応プロバイダを定義しておく
my $providers = [
    {
        url  => 'http://*.flickr.com/*',
        api  => 'http://www.flickr.com/services/oembed/',
    },
    {
        url  => 'http://*.wordpress.com/*',
        api  => 'http://public-api.wordpress.com/oembed/',
        params => {
            for => __PACKAGE__,
        },
    },
    {
        url  => 'http://twitter.com/*',
        api  => 'https://api.twitter.com/1/statuses/oembed.{format}',
        lang => 'lang',
    },
    {
        url => 'http://www.slideshare.net/*/*',
        api => 'http://www.slideshare.net/api/oembed/2',
    },
    {
        url => 'http://*.viddler.com/*',
        api => 'http://lab.viddler.com/services/oembed/',
    },
    {
        url => 'http://qik.com/*',
        api => 'http://qik.com/api/oembed.{format}',
    },
    {
        url => 'http://*.revision3.com/*',
        api => 'http://revision3.com/api/oembed/',
    },
    {
        url => 'http://www.hulu.com/watch/*',
        api => 'http://www.hulu.com/api/oembed.{format}',
    },
    {
        url => 'http://vimeo.com/*',
        api => 'http://vimeo.com/api/oembed.{format}',
    },
    {
        url => 'http://www.collegehumor.com/video/*',
        api => 'http://www.collegehumor.com/oembed.{format}',
    },
    {
        url => 'http://www.polleverywhere.com/*',
        api => 'http://www.polleverywhere.com/services/oembed/',
    },
    {
        url => 'http://www.ifixit.com/Guide/View/*',
        api => 'http://www.ifixit.com/Embed',
    },
    {
        url => 'http://*.smugmug.com/*',
        api => 'http://api.smugmug.com/services/oembed/',
    },

];

sub BUILD {
    my $self = shift;
    $self->register_provider($_) for @$providers;
    return $self;
}

# Twitter など http でも https でも1つの定義で動くように
override '_compile_url' => sub {
    my($self, $url) = @_;
    my $res = super();
    $res =~ s{^http:}{https?:};
    $res;
};

override 'request_url' => sub {
    my($self, $uri, $opt) = @_;
    my $req_uri = super();
    my $provider = $self->provider_for($uri);

    # oembed endpoint auto-discovery
    unless ($provider) {
        $req_uri = $self->request_url_from_link($uri);
        return $req_uri if $req_uri;
    }

    # それでもなければあきらめる
    $provider or return;

    # wordpress が for=hoge というクエリ付けないといけないので拡張
    if (my $params = $provider->{params}) {
        $req_uri->query_form(
            $req_uri->query_form,
            %$params,
        );
    }

    if (my $key = $provider->{lang}) {
        $req_uri->query_form(
            $req_uri->query_form,
            $key => $self->lang,
        );
    }

    return $req_uri;
};

sub request_url_from_link {
    my($self, $uri) = @_;
    my $res = $self->agent->get($uri);
    if ($res->is_success && $res->content =~ m{(<link[^>]*type=['"]?(?:application|text)/(?:json|xml)[+]oembed['"]?[^>]*>)}ix) {
        my $link = $1;
        if ($link =~ m{href=['"]?([^\s'">]+)}) {
            return $1;
        }
    }
    return;
}

sub render {
    my($self, $uri, $opt) = @_;
    $uri =~ s{/#!/}{/}; # twitter

    # 問い合わせ不要なもの
    for my $embed (@$embeds) {
        if ($uri =~ $embed->{regexp}) {
            if (ref $embed->{format} eq 'CODE') {
                return $embed->{format}->(\%+);
            } else {
                my $sub = template($embed->{format}, [keys %+]);
                return $sub->(\%+);
            }
        }
    }

    # oembed API
    my $key = join ':', 'oembed', $uri, sha1_hex(JSON::XS->new->canonical->encode($opt || {}));
    my $html;
    if ($self->cache) {
        $html = $self->cache->get($key);
    }
    unless (defined $html) {
        my $response = eval { $self->embed($uri, $opt) } or warn $@ and return;
        $html = $response->render || '';
        $html =~ s{\n\s*}{}g;
        if ($self->cache) {
            $self->cache->set($key, $html, 60 * 60 * 24 * 30);
        }
    }
    $html = Encode::decode('utf-8', $html) unless Encode::is_utf8($html);
    return $html;
}

sub unindent ($) {
    my $string = shift;
    my ($indent) = ($string =~ /^\n?(\s*)/);
    $string =~ s/^$indent//gm;
    $string =~ s/\s+$//;
    $string;
}

sub template ($$) { ## no critic
    my ($template, $keys) = @_;

    my $mt = Text::MicroTemplate->new(
        tag_start   => '{{',
        tag_end     => '}}',
        template    => unindent $template,
        escape_func => undef,
    );

    my $code     = $mt->code;
    my $expand   = join('; ', map { "my \$$_ = \$_[0]->{$_}" } @$keys);
    my $renderer = eval << "    ..." or die $@;
        sub {
            $expand;
            $code->();
        }
    ...
}

1;

__END__

=head1 NAME

Text::Hatena::Embed - All your URL are embeded to us

=head1 SYNOPSIS

  my $embed = Text::Hatena::Embed->new({
      cache => $cache,
      agent => $agent,
  });
  my $html = $embed->render($url);

=head1 DESCRIPTION

Text::Hatena::Embed is a module that embeds any URL.

=head1 SEE ALSO

L<http://www.oembed.com/>, L<https://dev.twitter.com/docs/api/1/get/statuses/oembed>

=cut
