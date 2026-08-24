import 'package:upload_core/upload_core.dart';

/// The destinations available to the application (§14, §28).
///
/// Which ones ship is a composition-root decision; nothing above this line may
/// know that Telegram or WebDAV exist.
abstract interface class DestinationRegistry {
  List<UploadDestination> get all;

  UploadDestination? byId(String id);

  /// The destination for [id], or the first registered one when it is unknown.
  UploadDestination resolve(String id);

  bool contains(String id);
}

/// The set of destinations this build ships with.
///
/// Adding S3 or OneDrive later means registering another implementation here
/// and nothing else in the recorder changes
/// (`docs/architecture/uploads.md`).
class UploadDestinationRegistry implements DestinationRegistry {
  UploadDestinationRegistry(List<UploadDestination> destinations)
    : _byId = <String, UploadDestination>{
        for (final UploadDestination d in destinations) d.id: d,
      },
      all = List<UploadDestination>.unmodifiable(destinations);

  final Map<String, UploadDestination> _byId;
  @override
  final List<UploadDestination> all;

  @override
  UploadDestination? byId(String id) => _byId[id];

  /// Falls back to the first registered destination when the persisted
  /// selection names something this build no longer ships.
  @override
  UploadDestination resolve(String id) => _byId[id] ?? all.first;

  @override
  bool contains(String id) => _byId.containsKey(id);
}
