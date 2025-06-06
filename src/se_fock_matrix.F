!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief Calculation of the Fock matrix for SE methods
!> \author JGH and TLAINO
!> \par History
!>      Teodoro Laino (04.2008) [tlaino] - University of Zurich : d-orbitals
!>      Teodoro Laino (09.2008) [tlaino] - University of Zurich : Speed-up
!>      Teodoro Laino (09.2008) [tlaino] - University of Zurich : Periodic SE
!>      Teodoro Laino (05.2009) [tlaino] - Split and module reorganization
! **************************************************************************************************
MODULE se_fock_matrix
   USE atomic_kind_types,               ONLY: atomic_kind_type
   USE atprop_types,                    ONLY: atprop_array_init,&
                                              atprop_type
   USE cp_control_types,                ONLY: dft_control_type,&
                                              semi_empirical_control_type
   USE cp_dbcsr_api,                    ONLY: dbcsr_add,&
                                              dbcsr_copy,&
                                              dbcsr_get_info,&
                                              dbcsr_multiply,&
                                              dbcsr_p_type,&
                                              dbcsr_type
   USE cp_dbcsr_contrib,                ONLY: dbcsr_dot
   USE cp_log_handling,                 ONLY: cp_get_default_logger,&
                                              cp_logger_type
   USE cp_output_handling,              ONLY: cp_print_key_finished_output,&
                                              cp_print_key_unit_nr
   USE input_constants,                 ONLY: &
        do_method_am1, do_method_mndo, do_method_mndod, do_method_pdg, do_method_pm3, &
        do_method_pm6, do_method_pm6fm, do_method_pnnl, do_method_rm1
   USE input_section_types,             ONLY: section_vals_get_subs_vals,&
                                              section_vals_type
   USE kinds,                           ONLY: dp
   USE message_passing,                 ONLY: mp_para_env_type
   USE particle_types,                  ONLY: particle_type
   USE qs_energy_types,                 ONLY: qs_energy_type
   USE qs_environment_types,            ONLY: get_qs_env,&
                                              qs_environment_type
   USE qs_ks_types,                     ONLY: qs_ks_env_type
   USE qs_mo_types,                     ONLY: get_mo_set,&
                                              mo_set_type
   USE qs_rho_types,                    ONLY: qs_rho_get,&
                                              qs_rho_type
   USE se_fock_matrix_coulomb,          ONLY: build_fock_matrix_coul_lr_r3,&
                                              build_fock_matrix_coulomb,&
                                              build_fock_matrix_coulomb_lr
   USE se_fock_matrix_dbg,              ONLY: dbg_energy_coulomb_lr
   USE se_fock_matrix_exchange,         ONLY: build_fock_matrix_exchange
   USE semi_empirical_store_int_types,  ONLY: semi_empirical_si_finalize,&
                                              semi_empirical_si_initialize,&
                                              semi_empirical_si_type
#include "./base/base_uses.f90"

   IMPLICIT NONE
   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'se_fock_matrix'
   LOGICAL, PARAMETER, PRIVATE          :: debug_this_module = .FALSE.
   LOGICAL, PARAMETER, PRIVATE          :: debug_energy_coulomb_lr = .FALSE.

   PUBLIC :: build_se_fock_matrix

CONTAINS

! **************************************************************************************************
!> \brief Construction of the Fock matrix for NDDO methods
!> \param qs_env ...
!> \param calculate_forces ...
!> \param just_energy ...
!> \par History
!>         - Teodoro Laino [tlaino] (05.2009) - Split and module reorganization
!> \author JGH
! **************************************************************************************************
   SUBROUTINE build_se_fock_matrix(qs_env, calculate_forces, just_energy)
      TYPE(qs_environment_type), POINTER                 :: qs_env
      LOGICAL, INTENT(in)                                :: calculate_forces, just_energy

      CHARACTER(len=*), PARAMETER :: routineN = 'build_se_fock_matrix'

      INTEGER                                            :: handle, ispin, natom, ncol_global, &
                                                            nspins, output_unit
      LOGICAL                                            :: s_mstruct_changed
      REAL(KIND=dp)                                      :: ecoul, qmmm_el
      REAL(KIND=dp), DIMENSION(:), POINTER               :: occupation_numbers
      TYPE(atomic_kind_type), DIMENSION(:), POINTER      :: atomic_kind_set
      TYPE(atprop_type), POINTER                         :: atprop
      TYPE(cp_logger_type), POINTER                      :: logger
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: ks_matrix, matrix_h, matrix_p, mo_derivs
      TYPE(dbcsr_type), POINTER                          :: mo_coeff
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(mo_set_type), DIMENSION(:), POINTER           :: mo_array
      TYPE(mp_para_env_type), POINTER                    :: para_env
      TYPE(particle_type), DIMENSION(:), POINTER         :: particle_set
      TYPE(qs_energy_type), POINTER                      :: energy
      TYPE(qs_ks_env_type), POINTER                      :: ks_env
      TYPE(qs_rho_type), POINTER                         :: rho
      TYPE(section_vals_type), POINTER                   :: scf_section
      TYPE(semi_empirical_control_type), POINTER         :: se_control
      TYPE(semi_empirical_si_type), POINTER              :: store_int_env

      CALL timeset(routineN, handle)
      NULLIFY (matrix_h, dft_control, logger, scf_section, store_int_env, se_control)
      NULLIFY (atomic_kind_set, atprop)
      NULLIFY (ks_env, ks_matrix, rho, energy)
      logger => cp_get_default_logger()
      CPASSERT(ASSOCIATED(qs_env))

      CALL get_qs_env(qs_env, &
                      dft_control=dft_control, &
                      matrix_h=matrix_h, &
                      para_env=para_env, &
                      se_store_int_env=store_int_env, &
                      atprop=atprop, &
                      atomic_kind_set=atomic_kind_set, &
                      s_mstruct_changed=s_mstruct_changed, &
                      ks_env=ks_env, &
                      matrix_ks=ks_matrix, &
                      rho=rho, &
                      energy=energy)

      SELECT CASE (dft_control%qs_control%method_id)
      CASE DEFAULT
         ! Abort if the parameterization is an unknown one..
         CPABORT("Fock Matrix not available for the chosen parameterization! ")

      CASE (do_method_am1, do_method_rm1, do_method_mndo, do_method_pdg, &
            do_method_pm3, do_method_pm6, do_method_pm6fm, do_method_mndod, do_method_pnnl)

         ! Check for properly allocation of Matrixes
         nspins = dft_control%nspins
         CPASSERT(((nspins >= 1) .AND. (nspins <= 2)))
         CPASSERT(ASSOCIATED(matrix_h))
         CPASSERT(ASSOCIATED(rho))
         CPASSERT(SIZE(ks_matrix) > 0)

         se_control => dft_control%qs_control%se_control
         scf_section => section_vals_get_subs_vals(qs_env%input, "DFT%SCF")
         CALL qs_rho_get(rho, rho_ao=matrix_p)

         energy%qmmm_el = 0.0_dp
         energy%total = 0.0_dp

         DO ispin = 1, nspins
            ! Copy the core matrix into the fock matrix
            CALL dbcsr_copy(ks_matrix(ispin)%matrix, matrix_h(1)%matrix)
         END DO

!      WRITE ( *, * ) 'KS_ENV%s_mstruct_changed', ks_env%s_mstruct_changed
         IF (atprop%energy) THEN
            CALL get_qs_env(qs_env=qs_env, particle_set=particle_set)
            natom = SIZE(particle_set)
            CALL atprop_array_init(atprop%atecoul, natom)
         END IF

         ! Compute Exchange and Coulomb terms
         CALL semi_empirical_si_initialize(store_int_env, s_mstruct_changed)
         CALL build_fock_matrix_exchange(qs_env, ks_matrix, matrix_p, calculate_forces, &
                                         store_int_env)
         CALL build_fock_matrix_coulomb(qs_env, ks_matrix, matrix_p, energy, calculate_forces, &
                                        store_int_env)

         ! Debug statements for Long-Range
         IF (debug_energy_coulomb_lr .AND. se_control%do_ewald) THEN
            CALL dbg_energy_coulomb_lr(energy, ks_matrix, nspins, qs_env, matrix_p, &
                                       calculate_forces, store_int_env)
         END IF

         ! Long Range Electrostatic
         IF (se_control%do_ewald) THEN
            ! Evaluate Coulomb Long-Range
            CALL build_fock_matrix_coulomb_lr(qs_env, ks_matrix, matrix_p, energy, calculate_forces, &
                                              store_int_env)

            ! Possibly handle the slowly convergent term 1/R^3
            IF (se_control%do_ewald_r3) THEN
               CALL build_fock_matrix_coul_lr_r3(qs_env, ks_matrix, matrix_p, energy, &
                                                 calculate_forces)
            END IF
         END IF
         CALL semi_empirical_si_finalize(store_int_env, s_mstruct_changed)

         IF (atprop%energy) THEN
            atprop%atecoul = 0.5_dp*atprop%atecoul
         END IF

         ! Compute the Hartree energy
         ! NOTE: If we are performing SCP-NDDO, ks_matrix contains coulomb piece from SCP.
         DO ispin = 1, nspins
            CALL dbcsr_dot(ks_matrix(ispin)%matrix, matrix_p(ispin)%matrix, ecoul)
            energy%hartree = energy%hartree + ecoul
         END DO
!      WRITE ( *, * ) 'AFTER Hartree',  ecoul, energy%hartree

!       CALL build_fock_matrix_ph(qs_env,ks_matrix)
         ! QM/MM
         IF (qs_env%qmmm) THEN
            DO ispin = 1, nspins
               ! If QM/MM sumup the 1el Hamiltonian
               CALL dbcsr_add(ks_matrix(ispin)%matrix, qs_env%ks_qmmm_env%matrix_h(1)%matrix, &
                              1.0_dp, 1.0_dp)
               ! Compute QM/MM Energy
               CALL dbcsr_dot(qs_env%ks_qmmm_env%matrix_h(1)%matrix, &
                              matrix_p(ispin)%matrix, qmmm_el)
               energy%qmmm_el = energy%qmmm_el + qmmm_el
            END DO
         END IF

!      WRITE ( *, * ) ' before TOTAL', energy%total
         ! Collect all the energy terms
         energy%mulliken = 0.0_dp
         energy%exc = 0.0_dp
         energy%total = energy%total + energy%core + &
                        energy%core_overlap + &
                        0.5_dp*energy%hartree + &
                        energy%qmmm_el + &
                        energy%dispersion + &
                        energy%mulliken
!      WRITE ( *, * ) ' AFTER TOTAL', energy%total

         output_unit = cp_print_key_unit_nr(logger, scf_section, "PRINT%DETAILED_ENERGY", &
                                            extension=".scfLog")

         IF (output_unit > 0) THEN
            WRITE (UNIT=output_unit, FMT="(/,(T3,A,T60,F20.10))") &
               "Core Hamiltonian energy:                       ", energy%core, &
               "Two-electron integral energy:                  ", energy%hartree
            IF (qs_env%qmmm) THEN
               WRITE (UNIT=output_unit, FMT="(T3,A,T60,F20.10)") &
                  "QM/MM Electrostatic energy:                    ", energy%qmmm_el
            END IF
         END IF

         CALL cp_print_key_finished_output(output_unit, logger, scf_section, &
                                           "PRINT%DETAILED_ENERGY")

         ! Here we compute dE/dC if needed. Assumes dE/dC is H_{ks}C (plus occupation numbers)
         IF (qs_env%requires_mo_derivs .AND. .NOT. just_energy) THEN
            CALL get_qs_env(qs_env, mo_derivs=mo_derivs, mos=mo_array)
            DO ispin = 1, SIZE(mo_derivs)
               CALL get_mo_set(mo_set=mo_array(ispin), &
                               mo_coeff_b=mo_coeff, occupation_numbers=occupation_numbers)
               IF (.NOT. mo_array(ispin)%use_mo_coeff_b) THEN
                  CPABORT("")
               END IF
               CALL dbcsr_get_info(mo_coeff, nfullcols_total=ncol_global)
               CALL dbcsr_multiply('n', 'n', 1.0_dp, ks_matrix(ispin)%matrix, mo_coeff, &
                                   0.0_dp, mo_derivs(ispin)%matrix)
            END DO
         END IF

      END SELECT

      CALL timestop(handle)

   END SUBROUTINE build_se_fock_matrix

END MODULE se_fock_matrix

