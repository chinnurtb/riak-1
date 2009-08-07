// JiakClient assumes the presence of jQuery and JSON libraries
// (or at least compatible $.ajax and JSON.stringify functions)
//
// Usage: instantiate a JiakClient with proper options, then use
// the store, fetch, remove, and walk function to get access to
// objects from Jiak.
//
// Examples:
//   var Client = new JiakClient('/jiak/');
//   Client.fetch('note', '123', function(note) {
//      note.object.text = 'Hello World';
//      Client.store(note);
//   });
//
//   Client.store({'bucket':'note'
//                 'object':{'text':'a new note'},
//                 'links':[]},
//                function(note) {
//                  alert('new note's key: '+note.key);
//                });
//
//   Client.walk(['note', '456'],
//               [{'bucket':'person', 'tag':'author'}],
//               function(data) {
//                 var authors = data.results[0];
//                 alert('note's author is: '+
//                       authors[0].object.name);
//               });
function JiakClient(BaseUrl, Opts) {
    this.baseurl = BaseUrl;
    if (!(this.baseurl.slice(-1) == '/'))
        this.baseurl += '/';

    this.opts = Opts||{};
}

JiakClient.prototype.store = function(Object, Callback, NoReturnBody) {
    var req = {
        contentType: "application/json",
        dataType: "json"
    };

    if (this.opts.alwaysPost || !Object.key)
        req.type = 'POST';
    else
        req.type = 'PUT';
    
    req.url = this.baseurl+Object.bucket+'/';
    if (Object.key) req.url += Object.key;
    
    if (!(this.opts.noReturnBody || NoReturnBody))
        req.url += '?returnbody=true';

    if (typeof Callback == 'function')
        req.success = Callback;

    req.data = JSON.stringify(Object);

    return $.ajax(req);
}

JiakClient.prototype.fetch = function(Bucket, Key, Callback) {
    return $.ajax({
        url:      this.baseurl+Bucket+'/'+Key,
        dataType: "json",
        success:  Callback
    });
}

JiakClient.prototype.remove = function(Bucket, Key, Callback) {
    return $.ajax({
        type:    'DELETE',
        url:     this.baseurl+Bucket+'/'+Key,
        success: Callback
    });
}

JiakClient.prototype.walk = function(Start, Spec, Callback) {
    var req = {
        dataType: "json",
        success: Callback
    };

    // Start can be either and object with {bucket:B, key:K}
    // or a list with [Bucket, Key, ...]
    if ('bucket' in Start)
        req.url = this.baseurl+Start.bucket+'/'+Start.key+'/';
    else
        req.url = this.baseurl+Start[0]+'/'+Start[1]+'/';

    // Spec should be a list of objects with
    //    {bucket:B, tag:T, acc:A}
    // where B and T specify the bucket and tag to match in the link
    //   or are undefined to match anything
    // and A is 'true' to get the objects matched at this step, or
    //   false to have them excluded from the response (always true
    //   for the last step
    for (i in Spec) {
        req.url += (Spec[i].bucket||'_')+','+
            (Spec[i].tag||'_')+','+
            ((Spec[i].acc || i == Spec.length-1) ? '1' : '_')+'/';
    }

    return $.ajax(req);
}
