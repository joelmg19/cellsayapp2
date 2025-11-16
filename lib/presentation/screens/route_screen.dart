import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import 'package:ultralytics_yolo_example/services/chile_transit_service.dart';
import 'package:ultralytics_yolo_example/services/route_service.dart';

class RouteScreen extends StatefulWidget {
  const RouteScreen({super.key});

  @override
  State<RouteScreen> createState() => _RouteScreenState();
}

enum SuggestionState { idle, loading, empty, error, ready }

class _RouteScreenState extends State<RouteScreen> {
  final _mapController = MapController();
  final _routeService = RouteService();
  final _transitService = ChileTransitService();
  final _tts = FlutterTts();
  final _destinationController = TextEditingController();
  final _destinationFocus = FocusNode();
  final DateFormat _timeFormat = DateFormat('HH:mm');

  LatLng? _userLocation;
  LatLng? _destination;
  RoutePlan? _routePlan;
  List<TransitVehicle> _vehicles = const [];
  List<PlaceSuggestion> _suggestions = const [];

  StreamSubscription<Position>? _positionSub;
  bool _isLocating = false;
  bool _planning = false;
  bool _loadingTransit = false;
  int _stepIndex = 0;
  SuggestionState _suggestionState = SuggestionState.idle;
  Timer? _debounce;
  CancellationToken? _searchToken;

  String? _status;

  @override
  void initState() {
    super.initState();
    _configureTts();
    _destinationFocus.addListener(() {
      if (!_destinationFocus.hasFocus) {
        setState(() {
          _suggestionState = SuggestionState.idle;
          _suggestions = const [];
        });
      }
    });
    _locateUser();
  }

  Future<void> _configureTts() async {
    await _tts.setLanguage('es-CL');
    await _tts.setSpeechRate(0.45);
    await _tts.setPitch(1.0);
  }

  Future<void> _locateUser() async {
    setState(() {
      _isLocating = true;
      _status = 'Obteniendo tu ubicación… (cargando)';
    });
    final hasPermission = await _ensurePermission();
    if (!hasPermission) {
      setState(() {
        _isLocating = false;
        _status = 'Activa los permisos de ubicación para utilizar Ruta.';
      });
      return;
    }
    final position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
    final userPoint = LatLng(position.latitude, position.longitude);
    setState(() {
      _userLocation = userPoint;
      _isLocating = false;
      _status = 'Ubicación lista. Estado: listo. Ingresa o dicta tu destino.';
    });
    _mapController.move(userPoint, 16);
    _subscribeToPosition();
  }

  Future<bool> _ensurePermission() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      await _tts.speak('Activa el GPS para continuar.');
      return false;
    }
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      return false;
    }
    return true;
  }

  void _subscribeToPosition() {
    _positionSub ??= Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 5),
    ).listen((position) {
      final current = LatLng(position.latitude, position.longitude);
      setState(() => _userLocation = current);
      if (_routePlan != null) {
        _evaluateProgress(current);
      }
    });
  }

  Future<void> _searchDestination() async {
    await _triggerAutocomplete(force: true);
    if (_suggestions.isEmpty) {
      setState(() => _status = 'Estado búsqueda: sin resultados.');
      return;
    }
    await _selectSuggestion(_suggestions.first);
  }

  void _onDestinationChanged(String value) {
    _debounce?.cancel();
    _searchToken?.cancel();
    if (value.trim().isEmpty) {
      setState(() {
        _suggestions = const [];
        _suggestionState = SuggestionState.idle;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () {
      unawaited(_triggerAutocomplete());
    });
  }

  Future<void> _triggerAutocomplete({bool force = false}) async {
    if (!force && !_destinationFocus.hasFocus) {
      return;
    }
    final query = _destinationController.text.trim();
    if (query.isEmpty) {
      setState(() {
        _suggestionState = SuggestionState.idle;
        _suggestions = const [];
      });
      return;
    }
    _searchToken?.cancel();
    final token = CancellationToken();
    _searchToken = token;
    setState(() {
      _suggestionState = SuggestionState.loading;
      _status = 'Estado búsqueda: cargando.';
    });
    try {
      final places = await _routeService.searchPlaces(query, bias: _userLocation, token: token);
      if (!mounted || token.isCancelled) return;
      setState(() {
        _suggestions = places.take(8).toList();
        _suggestionState = _suggestions.isEmpty ? SuggestionState.empty : SuggestionState.ready;
        _status = _suggestionState == SuggestionState.ready
            ? 'Estado búsqueda: listo. Selecciona un destino.'
            : 'Estado búsqueda: sin resultados.';
      });
    } catch (e, st) {
      developer.log('Autocomplete failure $e', name: '[ROUTE]', stackTrace: st);
      if (!mounted || token.isCancelled) return;
      setState(() {
        _suggestionState = SuggestionState.error;
        _suggestions = const [];
        _status = 'Estado búsqueda: error.';
      });
      _showSnack('No pude obtener sugerencias de destino.');
    }
  }

  Future<void> _selectSuggestion(PlaceSuggestion suggestion) async {
    _destinationController.text = suggestion.name;
    _destinationFocus.unfocus();
    setState(() {
      _suggestions = const [];
      _suggestionState = SuggestionState.idle;
      _destination = suggestion.point;
      _status = 'Destino seleccionado: ${suggestion.name}. Recalculando (listo cuando finalice)…';
    });
    _mapController.move(suggestion.point, 16);
    await _tts.speak('Destino ${suggestion.name} elegido.');
    await _planRoute();
  }

  Future<void> _planRoute() async {
    if (_userLocation == null || _destination == null) {
      setState(() => _status = 'Falta tu ubicación o el destino.');
      return;
    }
    setState(() {
      _planning = true;
      _status = 'Calculando ruta peatonal con mapas abiertos… (cargando)';
    });
    final plan = await _routeService.buildRoute(origin: _userLocation!, destination: _destination!);
    setState(() {
      _planning = false;
      _routePlan = plan;
      _stepIndex = 0;
      _status = plan == null ? 'No pude trazar ruta. (error)' : 'Ruta lista. Sigue las indicaciones.';
    });
    if (plan == null) {
      _showSnack('No logré construir la ruta.');
      await _tts.speak('No pude generar la ruta.');
      return;
    }
    await _tts.speak(
      'Ruta generada. Distancia ${plan.distanceMeters.toStringAsFixed(0)} metros, tiempo aproximado ${(plan.durationSeconds / 60).toStringAsFixed(0)} minutos.'
      ' Te avisaré cada vez que necesites girar o cruzar.',
    );
  }

  Future<void> _loadTransit() async {
    if (_userLocation == null) {
      setState(() => _status = 'Necesito tu ubicación para buscar transporte.');
      return;
    }
    setState(() {
      _loadingTransit = true;
      _status = 'Consultando datos abiertos de Red y Metro… (cargando)';
    });
    try {
      final vehicles = await _transitService.fetchVehicles(userPosition: _userLocation!, radiusMeters: 2500);
      setState(() {
        _loadingTransit = false;
        _vehicles = vehicles;
        _status = vehicles.isEmpty
            ? 'No encontré vehículos cercanos en tiempo real. (sin-resultados)'
            : 'Hay ${vehicles.length} servicios cercanos. (listo)';
      });
      if (vehicles.isEmpty) {
        await _tts.speak('No detecté buses o metro cercanos.');
      } else {
        final busCount = vehicles.where((v) => v.mode == TransitMode.bus).length;
        final metroCount = vehicles.where((v) => v.mode == TransitMode.metro).length;
        await _tts.speak('Detecté $busCount micros y $metroCount trenes en tu zona.');
      }
    } on TransitDataUnavailable catch (e) {
      developer.log('Transit unavailable: $e', name: '[ROUTE]');
      setState(() {
        _loadingTransit = false;
        _vehicles = const [];
        _status = 'Sin datos de transporte en vivo ahora.';
      });
      _showSnack('Sin datos de transporte en vivo ahora.');
    } catch (e, st) {
      developer.log('Transit error $e', name: '[ROUTE]', stackTrace: st);
      setState(() {
        _loadingTransit = false;
        _vehicles = const [];
        _status = 'Sin datos de transporte en vivo ahora.';
      });
      _showSnack('Sin datos de transporte en vivo ahora.');
    }
  }

  void _evaluateProgress(LatLng current) {
    final plan = _routePlan;
    if (plan == null || plan.instructions.isEmpty || _stepIndex >= plan.instructions.length) {
      return;
    }
    final currentStep = plan.instructions[_stepIndex];
    final distance = Geolocator.distanceBetween(
      current.latitude,
      current.longitude,
      currentStep.pivot.latitude,
      currentStep.pivot.longitude,
    );
    if (distance < 25) {
      _stepIndex++;
      unawaited(_tts.speak(currentStep.message));
      if (_stepIndex >= plan.instructions.length) {
        unawaited(_tts.speak('Ruta completada.'));
      }
    }
  }

  List<Marker> _buildMarkers() {
    final markers = <Marker>[];
    if (_userLocation != null) {
      markers.add(
        Marker(
          point: _userLocation!,
          width: 40,
          height: 40,
          child: const Icon(Icons.person_pin_circle, color: Colors.blue, size: 40),
        ),
      );
    }
    if (_destination != null) {
      markers.add(
        Marker(
          point: _destination!,
          width: 40,
          height: 40,
          child: const Icon(Icons.flag, color: Colors.red, size: 34),
        ),
      );
    }
    for (final vehicle in _vehicles.take(30)) {
      markers.add(
        Marker(
          point: vehicle.position,
          width: 32,
          height: 32,
          child: Tooltip(
            message: '${vehicle.provider} ${vehicle.lineName}',
            child: Icon(
              vehicle.mode == TransitMode.bus
                  ? Icons.directions_bus
                  : vehicle.mode == TransitMode.metro
                      ? Icons.subway
                      : Icons.train,
              color: vehicle.mode == TransitMode.bus
                  ? Colors.orange
                  : vehicle.mode == TransitMode.metro
                      ? Colors.green
                      : Colors.purple,
            ),
          ),
        ),
      );
    }
    return markers;
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _destinationController.dispose();
    _destinationFocus.dispose();
    _debounce?.cancel();
    _searchToken?.cancel();
    _tts.stop();
    super.dispose();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final center = _userLocation ?? const LatLng(-33.4489, -70.6693);
    final polylines = <Polyline>[
      if (_routePlan?.path.isNotEmpty ?? false)
        Polyline(points: _routePlan!.path, color: Theme.of(context).colorScheme.primary, strokeWidth: 5),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ruta asistida'),
        actions: [
          IconButton(
            onPressed: _locateUser,
            icon: const Icon(Icons.my_location),
            tooltip: 'Actualizar ubicación',
          )
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _destinationController,
                  focusNode: _destinationFocus,
                  decoration: InputDecoration(
                    labelText: 'Destino',
                    hintText: 'Ej: Metro Baquedano, Plaza, dirección…',
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.search),
                      onPressed: _searchDestination,
                    ),
                  ),
                  onSubmitted: (_) => _searchDestination(),
                  onChanged: _onDestinationChanged,
                  textInputAction: TextInputAction.search,
                ),
                const SizedBox(height: 8),
                if (_suggestionState != SuggestionState.idle)
                  _SuggestionPanel(
                    state: _suggestionState,
                    suggestions: _suggestions,
                    onSelected: _selectSuggestion,
                  ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _planning ? null : _planRoute,
                      icon: _planning
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.alt_route),
                      label: const Text('Calcular ruta'),
                    ),
                    ElevatedButton.icon(
                      onPressed: _loadingTransit ? null : _loadTransit,
                      icon: _loadingTransit
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.directions_bus),
                      label: const Text('Transporte Red/Metro'),
                    ),
                  ],
                ),
                if (_status != null) ...[
                  const SizedBox(height: 8),
                  Text(_status!, style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
          Expanded(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(initialCenter: center, initialZoom: 15),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'cl.cellsay.app',
                  maxZoom: 19,
                ),
                PolylineLayer(polylines: polylines),
                MarkerLayer(markers: _buildMarkers()),
              ],
            ),
          ),
          if (_vehicles.isNotEmpty)
            Container(
              height: 150,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              alignment: Alignment.centerLeft,
              child: Builder(
                builder: (context) {
                  final visible = _vehicles.take(12).toList();
                  return ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: visible.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 12),
                    itemBuilder: (context, index) {
                      final vehicle = visible[index];
                      final dist = vehicle.distanceToUser == null
                          ? '—'
                          : '${vehicle.distanceToUser!.toStringAsFixed(0)} m';
                      return Container(
                        width: 220,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${vehicle.provider} (${vehicle.lineName})', style: Theme.of(context).textTheme.titleMedium),
                            const SizedBox(height: 6),
                            Text('Distancia: $dist'),
                            if (vehicle.timestamp != null)
                              Text('Actualizado: ${_timeFormat.format(vehicle.timestamp!.toLocal())}'),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Mapas provistos por OpenStreetMap contributors y rutas OSRM, uso compatible con licencias ODbL/BSD.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SuggestionPanel extends StatelessWidget {
  const _SuggestionPanel({
    required this.state,
    required this.suggestions,
    required this.onSelected,
  });

  final SuggestionState state;
  final List<PlaceSuggestion> suggestions;
  final Future<void> Function(PlaceSuggestion) onSelected;

  @override
  Widget build(BuildContext context) {
    Widget child;
    switch (state) {
      case SuggestionState.loading:
        child = const Padding(
          padding: EdgeInsets.all(12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 12),
              Text('Buscando direcciones en Chile…'),
            ],
          ),
        );
        break;
      case SuggestionState.empty:
        child = const Padding(
          padding: EdgeInsets.all(12),
          child: Text('Sin resultados. Intenta con otro nombre.'),
        );
        break;
      case SuggestionState.error:
        child = const Padding(
          padding: EdgeInsets.all(12),
          child: Text('Error al obtener sugerencias.'),
        );
        break;
      case SuggestionState.ready:
        child = ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: suggestions.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final place = suggestions[index];
            return ListTile(
              dense: true,
              title: Text(place.name),
              subtitle: Text(place.address),
              onTap: () => unawaited(onSelected(place)),
            );
          },
        );
        break;
      case SuggestionState.idle:
      default:
        child = const SizedBox.shrink();
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: Container(
        key: ValueKey(state),
        width: double.infinity,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: child,
        ),
      ),
    );
  }
}
