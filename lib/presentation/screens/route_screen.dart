import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ultralytics_yolo_example/services/chile_transit_service.dart';
import 'package:ultralytics_yolo_example/services/route_service.dart';

class RouteScreen extends StatefulWidget {
  const RouteScreen({super.key});

  @override
  State<RouteScreen> createState() => _RouteScreenState();
}

enum SuggestionState { idle, loading, empty, error, ready }

enum TravelMode { walking, driving, transit }

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
  SharedPreferences? _prefs;
  TravelMode _selectedMode = TravelMode.walking;
  TravelMode? _lastCalculatedMode;
  DateTime? _lastPlanTap;

  @override
  void initState() {
    super.initState();
    _configureTts();
    unawaited(_loadPreferredMode());
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

  Future<void> _loadPreferredMode() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString('route_mode');
    final resolved = TravelMode.values.firstWhere(
      (mode) => mode.name == stored,
      orElse: () => TravelMode.walking,
    );
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _selectedMode = resolved;
    });
  }

  Future<void> _savePreferredMode(TravelMode mode) async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    await prefs.setString('route_mode', mode.name);
  }

  String _modeLabel(TravelMode mode) {
    switch (mode) {
      case TravelMode.walking:
        return 'Caminando';
      case TravelMode.driving:
        return 'Vehículo';
      case TravelMode.transit:
        return 'Transporte público';
    }
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
      _status = 'Destino seleccionado: ${suggestion.name}. Pulsa Calcular ruta para continuar.';
    });
    _mapController.move(suggestion.point, 16);
    await _tts.speak('Destino ${suggestion.name} elegido. Pulsa Calcular ruta para continuar.');
  }

  Future<void> _onPlanPressed() async {
    if (_planning) {
      _showSnack('Ya estoy calculando una ruta. Espera un momento.');
      return;
    }
    if (_userLocation == null || _destination == null) {
      _showSnack('Necesito tu ubicación y el destino para calcular.');
      return;
    }
    final now = DateTime.now();
    if (_lastPlanTap != null && now.difference(_lastPlanTap!) < const Duration(milliseconds: 900)) {
      return;
    }
    _lastPlanTap = now;
    final hasPermission = await _ensurePermission();
    if (!hasPermission) {
      _showSnack('Activa los permisos de ubicación para continuar.');
      return;
    }
    if (!mounted) return;
    await showModalBottomSheet<bool>(
      context: context,
      isDismissible: true,
      useSafeArea: true,
      builder: (sheetContext) {
        return _ModeSelectionSheet(
          initialMode: _selectedMode,
          onModeChanged: (mode) => setState(() => _selectedMode = mode),
          labelBuilder: _modeLabel,
          onConfirm: (mode) => _handleModeConfirmed(mode),
        );
      },
    );
  }

  Future<bool> _handleModeConfirmed(TravelMode mode) async {
    await _savePreferredMode(mode);
    await _tts.speak('Modo seleccionado: ${_modeLabel(mode)}');
    await _tts.speak('Calculando ruta…');
    final success = await _planRoute(mode);
    if (success) {
      _lastCalculatedMode = mode;
    }
    return success;
  }

  Future<bool> _planRoute(TravelMode mode) async {
    if (_userLocation == null || _destination == null) {
      setState(() => _status = 'Falta tu ubicación o el destino.');
      return false;
    }
    setState(() {
      _planning = true;
      _status = 'Calculando ruta ${_modeLabel(mode).toLowerCase()}… (cargando)';
    });
    try {
      RoutePlan? plan;
      if (mode == TravelMode.transit) {
        plan = await _buildTransitPlan().timeout(const Duration(seconds: 10));
      } else {
        final profile = mode == TravelMode.walking ? RouteProfile.walk : RouteProfile.drive;
        plan = await _routeService
            .buildRoute(origin: _userLocation!, destination: _destination!, profile: profile)
            .timeout(const Duration(seconds: 10));
      }
      if (!mounted) return false;
      setState(() {
        _planning = false;
        _routePlan = plan;
        _stepIndex = 0;
        _status = plan == null
            ? 'Sin resultados de ruta.'
            : 'Ruta ${_modeLabel(mode).toLowerCase()} lista. Sigue las indicaciones.';
      });
      if (plan == null) {
        _showSnack('No logré construir la ruta.');
        await _tts.speak('No pude generar la ruta.');
        return false;
      }
      _focusRouteOnMap(plan);
      await _tts.speak(
        'Ruta generada en modo ${_modeLabel(mode)}. Distancia ${plan.distanceMeters.toStringAsFixed(0)} metros, '
        'tiempo aproximado ${(plan.durationSeconds / 60).toStringAsFixed(0)} minutos. Te avisaré cada vez que necesites girar o cruzar.',
      );
      return true;
    } on TimeoutException {
      if (!mounted) return false;
      setState(() {
        _planning = false;
        _status = 'Tiempo de espera agotado al calcular la ruta.';
      });
      _showSnack('La solicitud tardó demasiado. Intenta nuevamente.');
      return false;
    } catch (e, st) {
      developer.log('Plan route failed $e', name: '[ROUTE]', stackTrace: st);
      if (!mounted) return false;
      setState(() {
        _planning = false;
        _status = 'Ocurrió un error al calcular la ruta.';
      });
      _showSnack('Ocurrió un error al calcular la ruta.');
      return false;
    }
  }

  Future<RoutePlan?> _buildTransitPlan() async {
    RoutePlan? walkingPlan;
    try {
      walkingPlan = await _routeService.buildRoute(
        origin: _userLocation!,
        destination: _destination!,
        profile: RouteProfile.walk,
      );
    } catch (e, st) {
      developer.log('Transit walking fallback failed $e', name: '[ROUTE]', stackTrace: st);
    }
    List<TransitVehicle> feed = const [];
    try {
      feed = await _transitService.fetchVehicles(userPosition: _userLocation!, radiusMeters: 2500);
      if (mounted) {
        setState(() => _vehicles = feed);
      }
    } catch (e, st) {
      developer.log('Transit feed unavailable $e', name: '[ROUTE]', stackTrace: st);
    }
    final instructions = <RouteInstruction>[];
    final path = walkingPlan?.path ?? [_userLocation!, if (_destination != null) _destination!];
    if (feed.isNotEmpty) {
      final closest = feed.first;
      instructions.add(
        RouteInstruction(
          message:
              'Camina hasta la parada más cercana y aborda ${closest.provider} ${closest.lineName}. Está a ${(closest.distanceToUser ?? 0).toStringAsFixed(0)} metros.',
          pivot: _userLocation!,
          distanceMeters: closest.distanceToUser ?? 0,
        ),
      );
      instructions.add(
        RouteInstruction(
          message:
              'Permanece en el servicio ${closest.lineName} hasta acercarte a tu destino y finaliza caminando los últimos metros.',
          pivot: closest.position,
          distanceMeters: closest.distanceToUser ?? 0,
        ),
      );
    } else {
      instructions.add(
        RouteInstruction(
          message:
              'Sin datos en vivo, utiliza tu ruta habitual de transporte público y sigue las instrucciones peatonales mostradas.',
          pivot: _userLocation!,
          distanceMeters: 0,
        ),
      );
    }
    if (walkingPlan != null) {
      instructions.addAll(walkingPlan.instructions);
    } else if (_destination != null) {
      instructions.add(
        RouteInstruction(
          message: 'Completa la caminata restante hasta tu destino.',
          pivot: _destination!,
          distanceMeters: 0,
        ),
      );
    }
    return RoutePlan(
      path: path,
      instructions: instructions,
      distanceMeters: walkingPlan?.distanceMeters ?? 0,
      durationSeconds: walkingPlan?.durationSeconds ?? 0,
      profile: RouteProfile.transit,
    );
  }

  void _focusRouteOnMap(RoutePlan plan) {
    if (plan.path.length < 2) return;
    final bounds = LatLngBounds.fromPoints(plan.path);
    if (!bounds.isValid) return;
    unawaited(
      _mapController.fitCamera(
        CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(48)),
      ),
    );
  }

  Future<void> _recalculateLastRoute() async {
    final mode = _lastCalculatedMode;
    if (mode == null || _planning) {
      return;
    }
    await _planRoute(mode);
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
                      onPressed: _planning ? null : _onPlanPressed,
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
                    ElevatedButton.icon(
                      onPressed: (!_planning && _lastCalculatedMode != null) ? _recalculateLastRoute : null,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Recalcular'),
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
            child: Column(
              children: [
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
                if ((_routePlan?.instructions.isNotEmpty ?? false))
                  SizedBox(
                    height: 220,
                    child: _InstructionList(
                      instructions: _routePlan!.instructions,
                      onSpeak: (message) => _tts.speak(message),
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
                                  Text('${vehicle.provider} (${vehicle.lineName})',
                                      style: Theme.of(context).textTheme.titleMedium),
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
              ],
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

class _InstructionList extends StatelessWidget {
  const _InstructionList({required this.instructions, required this.onSpeak});

  final List<RouteInstruction> instructions;
  final Future<void> Function(String) onSpeak;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Pasos de navegación',
      child: ListView.separated(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        itemCount: instructions.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final step = instructions[index];
          final title = 'Paso ${index + 1}';
          final subtitle = step.message;
          final distance = step.distanceMeters == 0
              ? ''
              : '${step.distanceMeters.toStringAsFixed(0)} m';
          return Semantics(
            button: true,
            label: distance.isEmpty ? '$title. $subtitle' : '$title. $subtitle. $distance',
            onTapHint: 'Reproducir con voz',
            child: Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                  child: Text('${index + 1}'),
                ),
                title: Text(title),
                subtitle: Text(subtitle),
                trailing: const Icon(Icons.volume_up),
                onTap: () => unawaited(onSpeak(subtitle)),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ModeSelectionSheet extends StatefulWidget {
  const _ModeSelectionSheet({
    required this.initialMode,
    required this.onModeChanged,
    required this.onConfirm,
    required this.labelBuilder,
  });

  final TravelMode initialMode;
  final ValueChanged<TravelMode> onModeChanged;
  final Future<bool> Function(TravelMode) onConfirm;
  final String Function(TravelMode) labelBuilder;

  @override
  State<_ModeSelectionSheet> createState() => _ModeSelectionSheetState();
}

class _ModeSelectionSheetState extends State<_ModeSelectionSheet> {
  late TravelMode _current = widget.initialMode;
  bool _submitting = false;
  String? _error;

  void _onChanged(TravelMode? mode) {
    if (mode == null || _submitting) return;
    setState(() => _current = mode);
    widget.onModeChanged(mode);
  }

  Future<void> _confirm() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final ok = await widget.onConfirm(_current);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _submitting = false;
        _error = 'No pude completar el cálculo. Intenta otra vez.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 24,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Selecciona cómo quieres desplazarte', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('La última elección se recordará. Este cálculo puede tardar hasta 10 segundos.',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            ...TravelMode.values.map(
              (mode) => RadioListTile<TravelMode>(
                title: Text(widget.labelBuilder(mode)),
                subtitle: Text(_subtitleForMode(mode)),
                value: mode,
                groupValue: _current,
                onChanged: _onChanged,
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _submitting ? null : () => Navigator.of(context).pop(false),
                    child: const Text('Cancelar'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _submitting ? null : _confirm,
                    icon: _submitting
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.check),
                    label: const Text('Confirmar'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _subtitleForMode(TravelMode mode) {
    switch (mode) {
      case TravelMode.walking:
        return 'OSRM y Valhalla para peatones con avisos de cruce.';
      case TravelMode.driving:
        return 'Vehículo particular (OSRM/Valhalla). Se requieren caminos habilitados.';
      case TravelMode.transit:
        return 'Combina caminatas con datos abiertos de transporte público chileno.';
    }
  }
}
