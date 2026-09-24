// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'csv_import.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$ImportOutcome {





@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is ImportOutcome);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'ImportOutcome()';
}


}

/// @nodoc
class $ImportOutcomeCopyWith<$Res>  {
$ImportOutcomeCopyWith(ImportOutcome _, $Res Function(ImportOutcome) __);
}


/// Adds pattern-matching-related methods to [ImportOutcome].
extension ImportOutcomePatterns on ImportOutcome {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( ImportOutcome_Completed value)?  completed,TResult Function( ImportOutcome_RolledBack value)?  rolledBack,TResult Function( ImportOutcome_Stopped value)?  stopped,required TResult orElse(),}){
final _that = this;
switch (_that) {
case ImportOutcome_Completed() when completed != null:
return completed(_that);case ImportOutcome_RolledBack() when rolledBack != null:
return rolledBack(_that);case ImportOutcome_Stopped() when stopped != null:
return stopped(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( ImportOutcome_Completed value)  completed,required TResult Function( ImportOutcome_RolledBack value)  rolledBack,required TResult Function( ImportOutcome_Stopped value)  stopped,}){
final _that = this;
switch (_that) {
case ImportOutcome_Completed():
return completed(_that);case ImportOutcome_RolledBack():
return rolledBack(_that);case ImportOutcome_Stopped():
return stopped(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( ImportOutcome_Completed value)?  completed,TResult? Function( ImportOutcome_RolledBack value)?  rolledBack,TResult? Function( ImportOutcome_Stopped value)?  stopped,}){
final _that = this;
switch (_that) {
case ImportOutcome_Completed() when completed != null:
return completed(_that);case ImportOutcome_RolledBack() when rolledBack != null:
return rolledBack(_that);case ImportOutcome_Stopped() when stopped != null:
return stopped(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  completed,TResult Function()?  rolledBack,TResult Function( String field0)?  stopped,required TResult orElse(),}) {final _that = this;
switch (_that) {
case ImportOutcome_Completed() when completed != null:
return completed();case ImportOutcome_RolledBack() when rolledBack != null:
return rolledBack();case ImportOutcome_Stopped() when stopped != null:
return stopped(_that.field0);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  completed,required TResult Function()  rolledBack,required TResult Function( String field0)  stopped,}) {final _that = this;
switch (_that) {
case ImportOutcome_Completed():
return completed();case ImportOutcome_RolledBack():
return rolledBack();case ImportOutcome_Stopped():
return stopped(_that.field0);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  completed,TResult? Function()?  rolledBack,TResult? Function( String field0)?  stopped,}) {final _that = this;
switch (_that) {
case ImportOutcome_Completed() when completed != null:
return completed();case ImportOutcome_RolledBack() when rolledBack != null:
return rolledBack();case ImportOutcome_Stopped() when stopped != null:
return stopped(_that.field0);case _:
  return null;

}
}

}

/// @nodoc


class ImportOutcome_Completed extends ImportOutcome {
  const ImportOutcome_Completed(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is ImportOutcome_Completed);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'ImportOutcome.completed()';
}


}




/// @nodoc


class ImportOutcome_RolledBack extends ImportOutcome {
  const ImportOutcome_RolledBack(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is ImportOutcome_RolledBack);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'ImportOutcome.rolledBack()';
}


}




/// @nodoc


class ImportOutcome_Stopped extends ImportOutcome {
  const ImportOutcome_Stopped(this.field0): super._();
  

 final  String field0;

/// Create a copy of ImportOutcome
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ImportOutcome_StoppedCopyWith<ImportOutcome_Stopped> get copyWith => _$ImportOutcome_StoppedCopyWithImpl<ImportOutcome_Stopped>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is ImportOutcome_Stopped&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode {
    return Object.hash(runtimeType,field0);
}

@override
String toString() {
    return 'ImportOutcome.stopped(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $ImportOutcome_StoppedCopyWith<$Res> implements $ImportOutcomeCopyWith<$Res> {
  factory $ImportOutcome_StoppedCopyWith(ImportOutcome_Stopped value, $Res Function(ImportOutcome_Stopped) _then) = _$ImportOutcome_StoppedCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$ImportOutcome_StoppedCopyWithImpl<$Res>
    implements $ImportOutcome_StoppedCopyWith<$Res> {
  _$ImportOutcome_StoppedCopyWithImpl(this._self, this._then);

  final ImportOutcome_Stopped _self;
  final $Res Function(ImportOutcome_Stopped) _then;

/// Create a copy of ImportOutcome
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(ImportOutcome_Stopped(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
mixin _$ImportStatus {

 Object get field0;



@override
bool operator ==(Object other) {
  final _this = this as ImportStatus;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ImportStatus&&const DeepCollectionEquality().equals(other.field0, _this.field0));
}


@override
int get hashCode {
  final _this = this as ImportStatus;
  return Object.hash(runtimeType,const DeepCollectionEquality().hash(_this.field0));
}

@override
String toString() {
  final _this = this as ImportStatus;
  return 'ImportStatus(field0: ${_this.field0})';
}


}

/// @nodoc
class $ImportStatusCopyWith<$Res>  {
$ImportStatusCopyWith(ImportStatus _, $Res Function(ImportStatus) __);
}


/// Adds pattern-matching-related methods to [ImportStatus].
extension ImportStatusPatterns on ImportStatus {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( ImportStatus_Running value)?  running,TResult Function( ImportStatus_Finished value)?  finished,required TResult orElse(),}){
final _that = this;
switch (_that) {
case ImportStatus_Running() when running != null:
return running(_that);case ImportStatus_Finished() when finished != null:
return finished(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( ImportStatus_Running value)  running,required TResult Function( ImportStatus_Finished value)  finished,}){
final _that = this;
switch (_that) {
case ImportStatus_Running():
return running(_that);case ImportStatus_Finished():
return finished(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( ImportStatus_Running value)?  running,TResult? Function( ImportStatus_Finished value)?  finished,}){
final _that = this;
switch (_that) {
case ImportStatus_Running() when running != null:
return running(_that);case ImportStatus_Finished() when finished != null:
return finished(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( ImportProgress field0)?  running,TResult Function( ImportReport field0)?  finished,required TResult orElse(),}) {final _that = this;
switch (_that) {
case ImportStatus_Running() when running != null:
return running(_that.field0);case ImportStatus_Finished() when finished != null:
return finished(_that.field0);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( ImportProgress field0)  running,required TResult Function( ImportReport field0)  finished,}) {final _that = this;
switch (_that) {
case ImportStatus_Running():
return running(_that.field0);case ImportStatus_Finished():
return finished(_that.field0);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( ImportProgress field0)?  running,TResult? Function( ImportReport field0)?  finished,}) {final _that = this;
switch (_that) {
case ImportStatus_Running() when running != null:
return running(_that.field0);case ImportStatus_Finished() when finished != null:
return finished(_that.field0);case _:
  return null;

}
}

}

/// @nodoc


class ImportStatus_Running extends ImportStatus {
  const ImportStatus_Running(this.field0): super._();
  

@override final  ImportProgress field0;

/// Create a copy of ImportStatus
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ImportStatus_RunningCopyWith<ImportStatus_Running> get copyWith => _$ImportStatus_RunningCopyWithImpl<ImportStatus_Running>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is ImportStatus_Running&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode {
    return Object.hash(runtimeType,field0);
}

@override
String toString() {
    return 'ImportStatus.running(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $ImportStatus_RunningCopyWith<$Res> implements $ImportStatusCopyWith<$Res> {
  factory $ImportStatus_RunningCopyWith(ImportStatus_Running value, $Res Function(ImportStatus_Running) _then) = _$ImportStatus_RunningCopyWithImpl;
@useResult
$Res call({
 ImportProgress field0
});




}
/// @nodoc
class _$ImportStatus_RunningCopyWithImpl<$Res>
    implements $ImportStatus_RunningCopyWith<$Res> {
  _$ImportStatus_RunningCopyWithImpl(this._self, this._then);

  final ImportStatus_Running _self;
  final $Res Function(ImportStatus_Running) _then;

/// Create a copy of ImportStatus
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(ImportStatus_Running(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as ImportProgress,
  ));
}


}

/// @nodoc


class ImportStatus_Finished extends ImportStatus {
  const ImportStatus_Finished(this.field0): super._();
  

@override final  ImportReport field0;

/// Create a copy of ImportStatus
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ImportStatus_FinishedCopyWith<ImportStatus_Finished> get copyWith => _$ImportStatus_FinishedCopyWithImpl<ImportStatus_Finished>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is ImportStatus_Finished&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode {
    return Object.hash(runtimeType,field0);
}

@override
String toString() {
    return 'ImportStatus.finished(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $ImportStatus_FinishedCopyWith<$Res> implements $ImportStatusCopyWith<$Res> {
  factory $ImportStatus_FinishedCopyWith(ImportStatus_Finished value, $Res Function(ImportStatus_Finished) _then) = _$ImportStatus_FinishedCopyWithImpl;
@useResult
$Res call({
 ImportReport field0
});




}
/// @nodoc
class _$ImportStatus_FinishedCopyWithImpl<$Res>
    implements $ImportStatus_FinishedCopyWith<$Res> {
  _$ImportStatus_FinishedCopyWithImpl(this._self, this._then);

  final ImportStatus_Finished _self;
  final $Res Function(ImportStatus_Finished) _then;

/// Create a copy of ImportStatus
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(ImportStatus_Finished(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as ImportReport,
  ));
}


}

// dart format on
