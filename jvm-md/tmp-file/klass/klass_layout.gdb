set pagination off
set print pretty on
set confirm off

# Break after class loading is complete
b InstanceKlass::allocate_instance_klass
run -Xms8g -Xmx8g -XX:+UseG1GC -Xint -cp /data/workspace/demo/src com.wjcoder.Main

# ===== 1. sizeof for all Klass types =====
printf "\n========== sizeof All Klass Types ==========\n"
printf "sizeof(Metadata)                    = %lu bytes\n", sizeof(Metadata)
printf "sizeof(Klass)                       = %lu bytes\n", sizeof(Klass)
printf "sizeof(InstanceKlass)               = %lu bytes\n", sizeof(InstanceKlass)
printf "sizeof(InstanceMirrorKlass)         = %lu bytes\n", sizeof(InstanceMirrorKlass)
printf "sizeof(InstanceRefKlass)            = %lu bytes\n", sizeof(InstanceRefKlass)
printf "sizeof(InstanceClassLoaderKlass)    = %lu bytes\n", sizeof(InstanceClassLoaderKlass)
printf "sizeof(ArrayKlass)                  = %lu bytes\n", sizeof(ArrayKlass)
printf "sizeof(ObjArrayKlass)               = %lu bytes\n", sizeof(ObjArrayKlass)
printf "sizeof(TypeArrayKlass)              = %lu bytes\n", sizeof(TypeArrayKlass)
printf "sizeof(OopMapBlock)                 = %lu bytes\n", sizeof(OopMapBlock)
printf "sizeof(AccessFlags)                 = %lu bytes\n", sizeof(AccessFlags)
printf "sizeof(OopHandle)                   = %lu bytes\n", sizeof(OopHandle)
printf "sizeof(KlassID)                     = %lu bytes\n", sizeof(KlassID)

# ===== 2. Klass base field offsets =====
printf "\n========== Klass Field Offsets ==========\n"
set $k = (Klass*)parser._klass
printf "Klass addr: %p\n", $k
printf "  &_layout_helper     - base = %lu\n", (size_t)&$k->_layout_helper - (size_t)$k
printf "  &_id                - base = %lu\n", (size_t)&$k->_id - (size_t)$k
printf "  &_super_check_offset- base = %lu\n", (size_t)&$k->_super_check_offset - (size_t)$k
printf "  &_name              - base = %lu\n", (size_t)&$k->_name - (size_t)$k
printf "  &_secondary_super_cache - base = %lu\n", (size_t)&$k->_secondary_super_cache - (size_t)$k
printf "  &_secondary_supers  - base = %lu\n", (size_t)&$k->_secondary_supers - (size_t)$k
printf "  &_primary_supers[0] - base = %lu\n", (size_t)&$k->_primary_supers[0] - (size_t)$k
printf "  &_java_mirror       - base = %lu\n", (size_t)&$k->_java_mirror - (size_t)$k
printf "  &_super             - base = %lu\n", (size_t)&$k->_super - (size_t)$k
printf "  &_subklass          - base = %lu\n", (size_t)&$k->_subklass - (size_t)$k
printf "  &_next_sibling      - base = %lu\n", (size_t)&$k->_next_sibling - (size_t)$k
printf "  &_next_link         - base = %lu\n", (size_t)&$k->_next_link - (size_t)$k
printf "  &_class_loader_data - base = %lu\n", (size_t)&$k->_class_loader_data - (size_t)$k
printf "  &_modifier_flags    - base = %lu\n", (size_t)&$k->_modifier_flags - (size_t)$k
printf "  &_access_flags      - base = %lu\n", (size_t)&$k->_access_flags - (size_t)$k
printf "  &_last_biased_lock_bulk_revocation_time - base = %lu\n", (size_t)&$k->_last_biased_lock_bulk_revocation_time - (size_t)$k
printf "  &_prototype_header  - base = %lu\n", (size_t)&$k->_prototype_header - (size_t)$k
printf "  &_biased_lock_revocation_count - base = %lu\n", (size_t)&$k->_biased_lock_revocation_count - (size_t)$k
printf "  &_vtable_len        - base = %lu\n", (size_t)&$k->_vtable_len - (size_t)$k
printf "  &_shared_class_path_index - base = %lu\n", (size_t)&$k->_shared_class_path_index - (size_t)$k

# ===== 3. InstanceKlass field offsets =====
printf "\n========== InstanceKlass Field Offsets ==========\n"
set $ik = (InstanceKlass*)parser._klass
printf "InstanceKlass addr: %p\n", $ik
printf "  &_annotations       - base = %lu\n", (size_t)&$ik->_annotations - (size_t)$ik
printf "  &_package_entry     - base = %lu\n", (size_t)&$ik->_package_entry - (size_t)$ik
printf "  &_array_klasses     - base = %lu\n", (size_t)&$ik->_array_klasses - (size_t)$ik
printf "  &_constants         - base = %lu\n", (size_t)&$ik->_constants - (size_t)$ik
printf "  &_inner_classes     - base = %lu\n", (size_t)&$ik->_inner_classes - (size_t)$ik
printf "  &_nest_members      - base = %lu\n", (size_t)&$ik->_nest_members - (size_t)$ik
printf "  &_nest_host_index   - base = %lu\n", (size_t)&$ik->_nest_host_index - (size_t)$ik
printf "  &_nest_host         - base = %lu\n", (size_t)&$ik->_nest_host - (size_t)$ik
printf "  &_source_debug_extension - base = %lu\n", (size_t)&$ik->_source_debug_extension - (size_t)$ik
printf "  &_array_name        - base = %lu\n", (size_t)&$ik->_array_name - (size_t)$ik
printf "  &_nonstatic_field_size - base = %lu\n", (size_t)&$ik->_nonstatic_field_size - (size_t)$ik
printf "  &_static_field_size - base = %lu\n", (size_t)&$ik->_static_field_size - (size_t)$ik
printf "  &_generic_signature_index - base = %lu\n", (size_t)&$ik->_generic_signature_index - (size_t)$ik
printf "  &_source_file_name_index - base = %lu\n", (size_t)&$ik->_source_file_name_index - (size_t)$ik
printf "  &_static_oop_field_count - base = %lu\n", (size_t)&$ik->_static_oop_field_count - (size_t)$ik
printf "  &_java_fields_count - base = %lu\n", (size_t)&$ik->_java_fields_count - (size_t)$ik
printf "  &_nonstatic_oop_map_size - base = %lu\n", (size_t)&$ik->_nonstatic_oop_map_size - (size_t)$ik
printf "  &_itable_len        - base = %lu\n", (size_t)&$ik->_itable_len - (size_t)$ik
printf "  &_is_marked_dependent - base = %lu\n", (size_t)&$ik->_is_marked_dependent - (size_t)$ik
printf "  &_is_being_redefined - base = %lu\n", (size_t)&$ik->_is_being_redefined - (size_t)$ik
printf "  &_misc_flags        - base = %lu\n", (size_t)&$ik->_misc_flags - (size_t)$ik
printf "  &_minor_version     - base = %lu\n", (size_t)&$ik->_minor_version - (size_t)$ik
printf "  &_major_version     - base = %lu\n", (size_t)&$ik->_major_version - (size_t)$ik
printf "  &_init_thread       - base = %lu\n", (size_t)&$ik->_init_thread - (size_t)$ik
printf "  &_oop_map_cache     - base = %lu\n", (size_t)&$ik->_oop_map_cache - (size_t)$ik
printf "  &_jni_ids           - base = %lu\n", (size_t)&$ik->_jni_ids - (size_t)$ik
printf "  &_methods_jmethod_ids - base = %lu\n", (size_t)&$ik->_methods_jmethod_ids - (size_t)$ik
printf "  &_dep_context       - base = %lu\n", (size_t)&$ik->_dep_context - (size_t)$ik
printf "  &_osr_nmethods_head - base = %lu\n", (size_t)&$ik->_osr_nmethods_head - (size_t)$ik
printf "  &_breakpoints       - base = %lu\n", (size_t)&$ik->_breakpoints - (size_t)$ik
printf "  &_previous_versions - base = %lu\n", (size_t)&$ik->_previous_versions - (size_t)$ik
printf "  &_cached_class_file - base = %lu\n", (size_t)&$ik->_cached_class_file - (size_t)$ik
printf "  &_idnum_allocated_count - base = %lu\n", (size_t)&$ik->_idnum_allocated_count - (size_t)$ik
printf "  &_init_state        - base = %lu\n", (size_t)&$ik->_init_state - (size_t)$ik
printf "  &_reference_type    - base = %lu\n", (size_t)&$ik->_reference_type - (size_t)$ik
printf "  &_this_class_index  - base = %lu\n", (size_t)&$ik->_this_class_index - (size_t)$ik
printf "  &_jvmti_cached_class_field_map - base = %lu\n", (size_t)&$ik->_jvmti_cached_class_field_map - (size_t)$ik
printf "  &_verify_count      - base = %lu\n", (size_t)&$ik->_verify_count - (size_t)$ik
printf "  &_methods           - base = %lu\n", (size_t)&$ik->_methods - (size_t)$ik
printf "  &_default_methods   - base = %lu\n", (size_t)&$ik->_default_methods - (size_t)$ik
printf "  &_local_interfaces  - base = %lu\n", (size_t)&$ik->_local_interfaces - (size_t)$ik
printf "  &_transitive_interfaces - base = %lu\n", (size_t)&$ik->_transitive_interfaces - (size_t)$ik
printf "  &_method_ordering   - base = %lu\n", (size_t)&$ik->_method_ordering - (size_t)$ik
printf "  &_default_vtable_indices - base = %lu\n", (size_t)&$ik->_default_vtable_indices - (size_t)$ik
printf "  &_fields            - base = %lu\n", (size_t)&$ik->_fields - (size_t)$ik

# ===== 4. InstanceKlass embedded layout =====
printf "\n========== InstanceKlass Embedded Layout ==========\n"
printf "  header_size (words)  = %d\n", sizeof(InstanceKlass)/8
printf "  header_size (bytes)  = %lu\n", sizeof(InstanceKlass)
printf "  vtable_length        = %d\n", $ik->_vtable_len
printf "  itable_length        = %d\n", $ik->_itable_len
printf "  nonstatic_oop_map_size = %d\n", $ik->_nonstatic_oop_map_size
printf "  init_state           = %d\n", (int)$ik->_init_state
printf "  layout_helper        = %d (0x%08x)\n", $ik->_layout_helper, $ik->_layout_helper

# ===== 5. ArrayKlass field offsets =====
printf "\n========== ArrayKlass Field Offsets (from type) ==========\n"
printf "  ArrayKlass::_dimension        offset = %lu\n", (size_t)&((ArrayKlass*)0)->_dimension
printf "  ArrayKlass::_higher_dimension offset = %lu\n", (size_t)&((ArrayKlass*)0)->_higher_dimension
printf "  ArrayKlass::_lower_dimension  offset = %lu\n", (size_t)&((ArrayKlass*)0)->_lower_dimension

# ===== 6. Klass constants =====
printf "\n========== Klass Constants ==========\n"
printf "  wordSize = %lu\n", (size_t)sizeof(void*)
printf "  sizeof(vtableEntry) = %lu\n", sizeof(vtableEntry)

# Continue to see a loaded class with more data
c
c
c

# Now try to dump info for a real loaded InstanceKlass
printf "\n========== Current InstanceKlass Values ==========\n"
set $ik2 = (InstanceKlass*)parser._klass
printf "class_name: %s\n", $ik2->_name->_body
printf "  layout_helper  = %d (0x%08x)\n", $ik2->_layout_helper, $ik2->_layout_helper
printf "  vtable_length  = %d\n", $ik2->_vtable_len
printf "  itable_length  = %d\n", $ik2->_itable_len
printf "  oop_map_size   = %d\n", $ik2->_nonstatic_oop_map_size
printf "  nonstatic_field_size = %d\n", $ik2->_nonstatic_field_size
printf "  static_field_size = %d\n", $ik2->_static_field_size
printf "  java_fields_count = %d\n", $ik2->_java_fields_count
printf "  init_state     = %d\n", (int)$ik2->_init_state
printf "  _id            = %d\n", (int)$ik2->_id
printf "  _misc_flags    = 0x%04x\n", $ik2->_misc_flags

quit
